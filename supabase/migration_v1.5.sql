-- ============================================================
-- 汪喵回家 — 資料庫升級 v1.5：檢舉與管理
--   1. profiles.is_admin（只能用 SQL 設定）＋ 收緊 profiles 可修改欄位
--   2. cases / found_reports 加 hidden；公開 view 一律排除隱藏內容
--   3. reports 檢舉表 + report_content RPC（任何人可檢舉，有頻率限制）
--   4. 管理員 RPC：列出檢舉、隱藏／恢復、退回目擊、標記已處理
-- 可重複執行，不刪資料。
-- ============================================================

-- 1. 管理員旗標 + 欄位權限（避免使用者自己把 is_admin 改成 true）
alter table public.profiles add column if not exists is_admin boolean not null default false;
revoke insert, update on public.profiles from authenticated;
grant insert (id, display_name, notify_enabled, notify_species, home_lat, home_lng, home_radius_km, notify_follow)
  on public.profiles to authenticated;
grant update (display_name, notify_enabled, notify_species, home_lat, home_lng, home_radius_km, notify_follow)
  on public.profiles to authenticated;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;
grant execute on function public.is_admin() to anon, authenticated;

-- 2. 隱藏欄位
alter table public.cases         add column if not exists hidden boolean not null default false;
alter table public.found_reports add column if not exists hidden boolean not null default false;

create or replace view public.cases_public with (security_invoker = false) as
select id, created_at, updated_at, last_activity, status, name, species, breed, sex, size,
       colour, age_text, features, has_chip, chip_last4, neutered, collar_desc, temperament,
       lost_at, lost_city, lost_district, lost_place, lost_lat, lost_lng, photos,
       contact_name,
       case when phone_public then contact_phone else null end as contact_phone,
       phone_public, contact_line, reward, notes, found_at, found_note, found_method, view_count,
       (select count(*) from public.sightings s where s.case_id = c.id and s.status='confirmed') as sighting_count,
       (select max(seen_at) from public.sightings s where s.case_id = c.id and s.status='confirmed') as last_seen_at
from public.cases c
where not c.hidden;

create or replace view public.found_public with (security_invoker = false) as
select id, created_at, updated_at, species, kind, status, seen_at, city, district, place_text, lat, lng,
       breed, sex, size, colour, features, collar_desc, current_place, photos, reporter_name,
       case when phone_public then reporter_phone else null end as reporter_phone,
       phone_public, reporter_line, notes
from public.found_reports
where not hidden;

create or replace view public.sightings_public with (security_invoker = false) as
select s.id, s.case_id, s.created_at, s.seen_at, s.lat, s.lng, s.place_text, s.direction, s.note, s.photo_url,
       s.reporter_name, s.status, s.owner_note, (s.reporter_id is not null) as verified
from public.sightings s join public.cases c on c.id = s.case_id
where s.status = 'confirmed' and not c.hidden;

create or replace view public.recent_sightings with (security_invoker = false) as
select s.id, s.case_id, s.seen_at, s.place_text, s.direction, s.photo_url,
       c.name as case_name, c.lost_city, c.lost_district, c.photos[1] as case_photo, c.species
from public.sightings s join public.cases c on c.id = s.case_id
where s.status = 'confirmed' and c.status = 'searching' and not c.hidden
order by s.seen_at desc
limit 20;

grant select on public.cases_public, public.found_public, public.sightings_public, public.recent_sightings to anon, authenticated;

-- 3. 檢舉
create table if not exists public.reports (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  target_type  text not null check (target_type in ('case','found','sighting')),
  target_id    uuid not null,
  reason       text not null check (reason in ('fake','spam','inappropriate','privacy','resolved','other')),
  note         text,
  reporter_id  uuid references auth.users(id) on delete set null,
  resolved     boolean not null default false,
  resolved_at  timestamptz,
  notified     boolean not null default false,
  constraint reports_len check (char_length(coalesce(note,'')) <= 500)
);
create index if not exists reports_open_idx on public.reports(resolved, created_at desc);
alter table public.reports enable row level security;

create or replace function public.report_content(p_type text, p_id uuid, p_reason text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_type not in ('case','found','sighting') then raise exception '類型錯誤'; end if;
  if (select count(*) from public.reports where created_at > now() - interval '10 minutes') >= 60 then
    raise exception '檢舉太頻繁，請稍後再試';
  end if;
  if p_type = 'case' and not exists (select 1 from public.cases where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'found' and not exists (select 1 from public.found_reports where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'sighting' and not exists (select 1 from public.sightings where id = p_id) then raise exception '找不到內容'; end if;
  -- 同一會員對同一內容只記一次
  if auth.uid() is not null and exists (select 1 from public.reports where reporter_id = auth.uid() and target_id = p_id and not resolved) then
    return;
  end if;
  insert into public.reports (target_type, target_id, reason, note, reporter_id)
  values (p_type, p_id, p_reason, left(p_note, 500), auth.uid());
end $$;
grant execute on function public.report_content(text, uuid, text, text) to anon, authenticated;

-- 4. 管理員 RPC
create or replace function public.admin_reports(p_include_resolved boolean default false)
returns table(id uuid, created_at timestamptz, target_type text, target_id uuid, reason text, note text,
              resolved boolean, target_title text, target_hidden boolean, report_count bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return query
  select r.id, r.created_at, r.target_type, r.target_id, r.reason, r.note, r.resolved,
         coalesce(c.name, case when f.id is not null then coalesce(f.colour,'') || ' ' || f.city end,
                  case when s.id is not null then '目擊：' || coalesce(s.place_text,'') end) as target_title,
         coalesce(c.hidden, f.hidden, false) as target_hidden,
         (select count(*) from public.reports r2 where r2.target_id = r.target_id and not r2.resolved) as report_count
  from public.reports r
  left join public.cases c on r.target_type = 'case' and c.id = r.target_id
  left join public.found_reports f on r.target_type = 'found' and f.id = r.target_id
  left join public.sightings s on r.target_type = 'sighting' and s.id = r.target_id
  where p_include_resolved or not r.resolved
  order by r.resolved, r.created_at desc
  limit 300;
end $$;

create or replace function public.admin_set_hidden(p_type text, p_id uuid, p_hidden boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then update public.cases set hidden = p_hidden where id = p_id;
  elsif p_type = 'found' then update public.found_reports set hidden = p_hidden where id = p_id;
  elsif p_type = 'sighting' then update public.sightings set status = case when p_hidden then 'rejected' else 'pending' end where id = p_id;
  else raise exception '類型錯誤'; end if;
end $$;

create or replace function public.admin_resolve(p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  update public.reports set resolved = true, resolved_at = now() where target_id = p_target and not resolved;
end $$;

create or replace function public.admin_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return jsonb_build_object(
    'open_reports', (select count(*) from public.reports where not resolved),
    'cases_searching', (select count(*) from public.cases where status = 'searching' and not hidden),
    'cases_found', (select count(*) from public.cases where status = 'found'),
    'found_open', (select count(*) from public.found_reports where status = 'open' and not hidden),
    'members', (select count(*) from public.profiles),
    'sightings_7d', (select count(*) from public.sightings where created_at > now() - interval '7 days'),
    'hidden', (select count(*) from public.cases where hidden) + (select count(*) from public.found_reports where hidden)
  );
end $$;

grant execute on function public.admin_reports(boolean), public.admin_set_hidden(text,uuid,boolean),
  public.admin_resolve(uuid), public.admin_stats() to authenticated;

grant all on public.reports to service_role;
grant all on all functions in schema public to service_role;

select 'WangMiao migration v1.5 installed' as result;

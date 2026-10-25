-- ============================================================
-- 汪回家 WangHome — 資料庫升級 v1.4：會員（可選）
--   1. profiles：顯示名稱、附近走失通知設定
--   2. 案件／拾獲通報加 owner_id：登入者建立的自動綁定，免金鑰管理
--   3. 管理 RPC 改為「金鑰 或 本人登入」都可以
--   4. claim：用金鑰把舊案件綁到帳號
--   5. follows：追蹤案件
--   6. pets：寵物檔案（私密）
--   7. 目擊回報記錄回報者帳號（顯示「會員回報」）
--   8. notify_log / notify_targets：給 daily.py 寄通知用
-- 可重複執行，不刪資料。
-- ============================================================

-- ------------------------------------------------------------
-- 1. profiles
-- ------------------------------------------------------------
create table if not exists public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  created_at       timestamptz not null default now(),
  display_name     text,
  notify_enabled   boolean not null default false,
  notify_species   text not null default 'all' check (notify_species in ('all','dog','cat')),
  home_lat         double precision,
  home_lng         double precision,
  home_radius_km   integer not null default 3 check (home_radius_km between 1 and 30),
  notify_follow    boolean not null default true,
  constraint profiles_len check (char_length(coalesce(display_name,'')) <= 30)
);
alter table public.profiles enable row level security;
drop policy if exists "own profile select" on public.profiles;
drop policy if exists "own profile insert" on public.profiles;
drop policy if exists "own profile update" on public.profiles;
create policy "own profile select" on public.profiles for select to authenticated using (id = auth.uid());
create policy "own profile insert" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "own profile update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
grant select, insert, update on public.profiles to authenticated;

-- 新會員自動建立 profile
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, split_part(coalesce(new.email,''), '@', 1))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------------------
-- 2. owner_id
-- ------------------------------------------------------------
alter table public.cases         add column if not exists owner_id uuid references auth.users(id) on delete set null;
alter table public.found_reports add column if not exists owner_id uuid references auth.users(id) on delete set null;
alter table public.sightings     add column if not exists reporter_id uuid references auth.users(id) on delete set null;
create index if not exists cases_owner_idx on public.cases(owner_id);
create index if not exists found_owner_idx on public.found_reports(owner_id);

-- 建立時自動帶入登入者（匿名則為 null）
create or replace function public.set_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.owner_id := auth.uid();
  return new;
end $$;
drop trigger if exists cases_set_owner on public.cases;
create trigger cases_set_owner before insert on public.cases for each row execute function public.set_owner();
drop trigger if exists found_set_owner on public.found_reports;
create trigger found_set_owner before insert on public.found_reports for each row execute function public.set_owner();

-- 目擊回報：記錄回報者帳號（不可偽造）
create or replace function public.limit_sightings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.sightings where case_id = new.case_id and created_at > now() - interval '10 minutes') >= 30 then
    raise exception '這個案件短時間內回報太多次，請稍後再試';
  end if;
  new.status := 'pending';
  new.notified := false;
  new.reporter_id := auth.uid();
  return new;
end $$;

-- 公開目擊加「會員回報」標記
create or replace view public.sightings_public with (security_invoker = false) as
select id, case_id, created_at, seen_at, lat, lng, place_text, direction, note, photo_url,
       reporter_name, status, owner_note, (reporter_id is not null) as verified
from public.sightings where status = 'confirmed';
grant select on public.sightings_public to anon, authenticated;

-- ------------------------------------------------------------
-- 3. 管理權限：金鑰 或 本人
-- ------------------------------------------------------------
create or replace function public.can_manage_case(p_id uuid, p_token text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.cases
    where id = p_id
      and ( (p_token is not null and p_token <> '' and edit_token = encode(digest(p_token,'sha256'),'hex'))
            or (auth.uid() is not null and owner_id = auth.uid()) )
  );
$$;
create or replace function public.can_manage_found(p_id uuid, p_token text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.found_reports
    where id = p_id
      and ( (p_token is not null and p_token <> '' and edit_token = encode(digest(p_token,'sha256'),'hex'))
            or (auth.uid() is not null and owner_id = auth.uid()) )
  );
$$;

create or replace function public.owner_case(p_id uuid, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.cases;
begin
  if not public.can_manage_case(p_id, p_token) then raise exception '管理連結無效'; end if;
  select * into r from public.cases where id = p_id;
  return (to_jsonb(r) - 'edit_token') || jsonb_build_object('is_mine', r.owner_id is not null and r.owner_id = auth.uid());
end $$;

create or replace function public.update_case(p_id uuid, p_token text, p jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.can_manage_case(p_id, p_token) then raise exception '管理連結無效'; end if;
  update public.cases set
    status        = coalesce(nullif(p->>'status',''), status),
    name          = coalesce(p->>'name', name),
    breed         = coalesce(p->>'breed', breed),
    colour        = coalesce(p->>'colour', colour),
    features      = coalesce(p->>'features', features),
    collar_desc   = coalesce(p->>'collar_desc', collar_desc),
    temperament   = coalesce(p->>'temperament', temperament),
    lost_place    = coalesce(p->>'lost_place', lost_place),
    contact_name  = coalesce(p->>'contact_name', contact_name),
    contact_phone = coalesce(p->>'contact_phone', contact_phone),
    phone_public  = coalesce((p->>'phone_public')::boolean, phone_public),
    contact_email = coalesce(p->>'contact_email', contact_email),
    contact_line  = coalesce(p->>'contact_line', contact_line),
    reward        = coalesce((p->>'reward')::integer, reward),
    notes         = coalesce(p->>'notes', notes),
    photos        = case when p ? 'photos'
                      then coalesce((select array_agg(x) from jsonb_array_elements_text(p->'photos') x), '{}')
                      else photos end,
    found_at      = case when p->>'status' = 'found' then coalesce(found_at, now()) else found_at end,
    found_note    = coalesce(p->>'found_note', found_note),
    found_method  = coalesce(p->>'found_method', found_method),
    updated_at    = now(),
    last_activity = now()
  where id = p_id;
end $$;

create or replace function public.owner_sightings(p_id uuid, p_token text)
returns setof public.sightings language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.can_manage_case(p_id, p_token) then raise exception '管理連結無效'; end if;
  return query select * from public.sightings where case_id = p_id order by seen_at desc;
end $$;

create or replace function public.set_sighting_status(p_case uuid, p_sighting uuid, p_token text, p_status text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_status not in ('pending','confirmed','rejected') then raise exception '狀態錯誤'; end if;
  if not public.can_manage_case(p_case, p_token) then raise exception '管理連結無效'; end if;
  update public.sightings set status = p_status where id = p_sighting and case_id = p_case;
end $$;

create or replace function public.dismiss_match(p_case uuid, p_match uuid, p_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.can_manage_case(p_case, p_token) then raise exception '管理連結無效'; end if;
  update public.shelter_matches set dismissed = true where id = p_match and case_id = p_case;
end $$;

create or replace function public.owner_found(p_id uuid, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.found_reports;
begin
  if not public.can_manage_found(p_id, p_token) then raise exception '管理連結無效'; end if;
  select * into r from public.found_reports where id = p_id;
  return (to_jsonb(r) - 'edit_token') || jsonb_build_object('is_mine', r.owner_id is not null and r.owner_id = auth.uid());
end $$;

create or replace function public.update_found(p_id uuid, p_token text, p jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.can_manage_found(p_id, p_token) then raise exception '管理連結無效'; end if;
  update public.found_reports set
    status        = coalesce(nullif(p->>'status',''), status),
    current_place = coalesce(p->>'current_place', current_place),
    notes         = coalesce(p->>'notes', notes),
    reporter_phone= coalesce(p->>'reporter_phone', reporter_phone),
    phone_public  = coalesce((p->>'phone_public')::boolean, phone_public),
    updated_at    = now()
  where id = p_id;
end $$;

-- ------------------------------------------------------------
-- 4. 認領（用金鑰把案件綁到目前登入的帳號）
-- ------------------------------------------------------------
create or replace function public.claim_case(p_id uuid, p_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  update public.cases set owner_id = auth.uid()
   where id = p_id and owner_id is null
     and edit_token = encode(digest(coalesce(p_token,''),'sha256'),'hex');
  if not found then raise exception '無法綁定（金鑰錯誤或已有擁有者）'; end if;
end $$;
create or replace function public.claim_found(p_id uuid, p_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  update public.found_reports set owner_id = auth.uid()
   where id = p_id and owner_id is null
     and edit_token = encode(digest(coalesce(p_token,''),'sha256'),'hex');
  if not found then raise exception '無法綁定（金鑰錯誤或已有擁有者）'; end if;
end $$;

-- 我的案件／我的拾獲通報
create or replace function public.my_cases()
returns setof public.cases_public language sql stable security definer set search_path = public as $$
  select cp.* from public.cases_public cp join public.cases c on c.id = cp.id
  where auth.uid() is not null and c.owner_id = auth.uid()
  order by cp.last_activity desc;
$$;
create or replace function public.my_found()
returns setof public.found_public language sql stable security definer set search_path = public as $$
  select fp.* from public.found_public fp join public.found_reports f on f.id = fp.id
  where auth.uid() is not null and f.owner_id = auth.uid()
  order by fp.seen_at desc;
$$;
-- 待確認目擊數（給「我的案件」顯示紅點）
create or replace function public.my_pending_counts()
returns table(case_id uuid, pending bigint) language sql stable security definer set search_path = public as $$
  select s.case_id, count(*) from public.sightings s join public.cases c on c.id = s.case_id
  where auth.uid() is not null and c.owner_id = auth.uid() and s.status = 'pending'
  group by s.case_id;
$$;

-- ------------------------------------------------------------
-- 5. 追蹤案件
-- ------------------------------------------------------------
create table if not exists public.follows (
  user_id    uuid not null references auth.users(id) on delete cascade,
  case_id    uuid not null references public.cases(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, case_id)
);
alter table public.follows enable row level security;
drop policy if exists "own follows" on public.follows;
create policy "own follows" on public.follows for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, delete on public.follows to authenticated;

create or replace function public.follow_count(p_case uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select count(*) from public.follows where case_id = p_case;
$$;

-- ------------------------------------------------------------
-- 6. 寵物檔案（只有本人看得到）
-- ------------------------------------------------------------
create table if not exists public.pets (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  species     text not null default 'dog' check (species in ('dog','cat')),
  name        text not null,
  breed       text,
  sex         text check (sex in ('male','female','unknown')),
  size        text check (size in ('small','medium','large')),
  colour      text,
  age_text    text,
  birthday    date,
  features    text,
  temperament text,
  has_chip    boolean default false,
  chip_no     text,              -- 完整晶片號碼（私密）
  neutered    boolean,
  photos      text[] default '{}',
  notes       text,
  constraint pets_len check (
    char_length(name) between 1 and 30 and
    char_length(coalesce(features,'')) <= 1000 and
    char_length(coalesce(notes,'')) <= 2000 and
    char_length(coalesce(chip_no,'')) <= 20 and
    coalesce(array_length(photos,1),0) <= 6
  )
);
alter table public.pets enable row level security;
drop policy if exists "own pets" on public.pets;
create policy "own pets" on public.pets for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
grant select, insert, update, delete on public.pets to authenticated;

-- 每人最多 20 隻
create or replace function public.limit_pets() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.pets where owner_id = auth.uid()) >= 20 then raise exception '寵物檔案已達上限'; end if;
  new.owner_id := auth.uid();
  return new;
end $$;
drop trigger if exists pets_limit on public.pets;
create trigger pets_limit before insert on public.pets for each row execute function public.limit_pets();

-- ------------------------------------------------------------
-- 8. 通知（daily.py 用 service_role 呼叫）
-- ------------------------------------------------------------
create table if not exists public.notify_log (
  user_id  uuid not null references auth.users(id) on delete cascade,
  kind     text not null,      -- 'nearby' | 'follow'
  ref_id   uuid not null,      -- case_id 或 sighting_id
  sent_at  timestamptz not null default now(),
  primary key (user_id, kind, ref_id)
);
alter table public.notify_log enable row level security;

-- 附近新案件：回傳 (email, case) 尚未寄過的組合
create or replace function public.nearby_targets(p_hours integer default 26)
returns table(user_id uuid, email text, case_id uuid, case_name text, species text, lost_city text,
              lost_district text, lost_place text, distance_km double precision)
language sql stable security definer set search_path = public, auth as $$
  select p.id, u.email::text, c.id, c.name, c.species, c.lost_city, c.lost_district, c.lost_place,
         6371 * 2 * asin(sqrt(power(sin(radians(c.lost_lat - p.home_lat)/2),2) +
           cos(radians(p.home_lat)) * cos(radians(c.lost_lat)) * power(sin(radians(c.lost_lng - p.home_lng)/2),2))) as d
  from public.profiles p
  join auth.users u on u.id = p.id
  join public.cases c on c.status = 'searching' and c.lost_lat is not null
       and c.created_at > now() - make_interval(hours => p_hours)
       and (p.notify_species = 'all' or p.notify_species = c.species)
       and (c.owner_id is null or c.owner_id <> p.id)
  where p.notify_enabled and p.home_lat is not null and u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = p.id and l.kind = 'nearby' and l.ref_id = c.id)
    and 6371 * 2 * asin(sqrt(power(sin(radians(c.lost_lat - p.home_lat)/2),2) +
           cos(radians(p.home_lat)) * cos(radians(c.lost_lat)) * power(sin(radians(c.lost_lng - p.home_lng)/2),2))) <= p.home_radius_km;
$$;

-- 追蹤案件的新確認目擊
create or replace function public.follow_targets(p_hours integer default 26)
returns table(user_id uuid, email text, case_id uuid, case_name text, sighting_id uuid, seen_at timestamptz, place_text text)
language sql stable security definer set search_path = public, auth as $$
  select f.user_id, u.email::text, c.id, c.name, s.id, s.seen_at, s.place_text
  from public.follows f
  join public.profiles p on p.id = f.user_id and p.notify_follow
  join auth.users u on u.id = f.user_id
  join public.cases c on c.id = f.case_id and c.status = 'searching'
  join public.sightings s on s.case_id = c.id and s.status = 'confirmed' and s.created_at > now() - make_interval(hours => p_hours)
  where u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = f.user_id and l.kind = 'follow' and l.ref_id = s.id);
$$;

revoke all on function public.nearby_targets(integer) from public, anon, authenticated;
revoke all on function public.follow_targets(integer) from public, anon, authenticated;
grant execute on function public.nearby_targets(integer) to service_role;
grant execute on function public.follow_targets(integer) to service_role;

-- 權限
grant execute on function public.can_manage_case(uuid,text), public.can_manage_found(uuid,text),
  public.claim_case(uuid,text), public.claim_found(uuid,text), public.my_cases(), public.my_found(),
  public.my_pending_counts(), public.follow_count(uuid) to anon, authenticated;
grant all on public.profiles, public.follows, public.pets, public.notify_log to service_role;
grant all on all functions in schema public to service_role;

-- 既有使用者補 profile（若有）
insert into public.profiles (id, display_name)
select id, split_part(coalesce(email,''), '@', 1) from auth.users
on conflict (id) do nothing;

select 'WangHome migration v1.4 installed' as result;

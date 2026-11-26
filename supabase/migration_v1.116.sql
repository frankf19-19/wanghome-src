-- 汪喵回家 migration v1.116 — 狀態異動紀錄：走失案件／拾獲通報的狀態是誰改的、幾點改的
--   後台「網友發佈」會顯示最後一次異動：本人（登入）、編輯連結（沒登入）、管理員、系統自動
--   可重複執行。

create table if not exists public.status_log (
  id         bigint generated always as identity primary key,
  kind       text not null,               -- case / found
  ref_id     uuid not null,
  old_status text,
  new_status text,
  at         timestamptz not null default now(),
  actor      uuid,                        -- 登入的人（沒登入或系統就是空的）
  actor_kind text not null                -- owner 本人 / admin 管理員 / member 其他會員 / link 編輯連結 / system 系統
);
create index if not exists status_log_ref_idx on public.status_log(kind, ref_id, at desc);
alter table public.status_log enable row level security;
revoke all on public.status_log from anon, authenticated;
grant select, insert on public.status_log to service_role;

create or replace function public.status_log_trg() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid; v_role text; v_kind text;
begin
  if new.status is not distinct from old.status then return new; end if;
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  begin v_role := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'; exception when others then v_role := null; end;
  v_kind := case
    when v_uid is not null and v_uid = new.owner_id then 'owner'
    when v_uid is not null and exists (select 1 from public.profiles p where p.id = v_uid and coalesce(p.is_admin, false)) then 'admin'
    when v_uid is not null then 'member'
    when v_role = 'anon' then 'link'
    else 'system' end;
  insert into public.status_log (kind, ref_id, old_status, new_status, actor, actor_kind)
  values (tg_argv[0], new.id, old.status, new.status, v_uid, v_kind);
  return new;
exception when others then return new;   -- 紀錄失敗不能擋住使用者的操作
end $$;
revoke all on function public.status_log_trg() from public, anon, authenticated;

drop trigger if exists cases_status_log on public.cases;
create trigger cases_status_log after update of status on public.cases
  for each row execute function public.status_log_trg('case');
drop trigger if exists found_status_log on public.found_reports;
create trigger found_status_log after update of status on public.found_reports
  for each row execute function public.status_log_trg('found');

-- 後台「網友發佈」：多帶最後一次狀態異動
create or replace function public.admin_site_posts(p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare j jsonb;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  with adm as (select id from public.profiles where coalesce(is_admin, false)),
  feed as (
    select 'case'::text as type, c.id, c.created_at, c.name as title, c.species, c.status, c.hidden,
           concat_ws(' ', c.lost_city, c.lost_district, c.lost_place) as area,
           left(concat_ws(E'\n', nullif(c.features,''), nullif(c.notes,'')), 400) as body,
           c.photos[1] as photo, null::uuid as case_id, c.owner_id as uid,
           c.contact_name as who, c.contact_phone as phone, c.found_at as closed_at
      from public.cases c
     where c.source = 'site' and (c.owner_id is null or c.owner_id not in (select id from adm))
    union all
    select 'found', f.id, f.created_at, concat_ws('・', case when f.kind = 'found' then '撿到' else '看到' end, nullif(f.breed,''), nullif(f.colour,'')),
           null, f.status, f.hidden, concat_ws(' ', f.city, f.district, f.place_text),
           left(concat_ws(E'\n', nullif(f.features,''), nullif(f.notes,'')), 400), f.photos[1], null, f.owner_id,
           f.reporter_name, f.reporter_phone, null::timestamptz
      from public.found_reports f
     where f.owner_id is null or f.owner_id not in (select id from adm)
    union all
    select 'sighting', s.id, s.created_at, '目擊回報：' || coalesce(c.name, '案件'), null, s.status, false,
           concat_ws(' ', nullif(s.place_text,''), case when nullif(s.direction,'') is not null then '往' || s.direction end),
           left(coalesce(s.note,''), 400), s.photo_url, s.case_id, s.reporter_id,
           s.reporter_name, s.reporter_contact, null::timestamptz
      from public.sightings s left join public.cases c on c.id = s.case_id
     where s.reporter_id is null or s.reporter_id not in (select id from adm)
  )
  select coalesce(jsonb_agg(x order by x.created_at desc), '[]') into j from (
    select f.*, u.email as member_email, p.display_name,
           l.at as status_at, l.actor_kind as status_by, l.old_status as status_from, l.new_status as status_to
      from feed f left join auth.users u on u.id = f.uid left join public.profiles p on p.id = f.uid
      left join lateral (select sl.at, sl.actor_kind, sl.old_status, sl.new_status from public.status_log sl
                          where sl.kind = f.type and sl.ref_id = f.id order by sl.at desc limit 1) l on true
     order by f.created_at desc offset greatest(p_offset, 0) limit 50) x;
  return j;
end $$;
revoke all on function public.admin_site_posts(int) from public, anon;
grant execute on function public.admin_site_posts(int) to authenticated;

select count(*) as status_log_rows from public.status_log;

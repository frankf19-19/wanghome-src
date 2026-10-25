-- 汪喵回家 migration v1.10 — 安全性與排程修正
--   1. 照片網址只允許本專案 Storage（防止塞入惡意網址）
--   2. 「附近走失」通知排除已被站長隱藏的案件
--   3. 健康提醒用台灣日期計算（避免 UTC 差 8 小時算錯天）
-- 可重複執行。

-- 1. 照片網址檢查 ---------------------------------------------------------
create or replace function public.photo_url_ok(u text)
returns boolean language sql immutable as $$
  select u is null or (
    u like 'https://nopyhfpaykkiieudvoko.supabase.co/storage/v1/object/public/photos/%'
    and u !~ '[\s''"()<>\\]'
    and char_length(u) <= 300
  );
$$;
create or replace function public.photo_urls_ok(a text[])
returns boolean language sql immutable as $$
  select a is null or (coalesce(array_length(a,1),0) <= 10
    and not exists (select 1 from unnest(a) x where not public.photo_url_ok(x)));
$$;

alter table public.cases         drop constraint if exists cases_photos_ok;
alter table public.cases         add  constraint cases_photos_ok  check (public.photo_urls_ok(photos)) not valid;
alter table public.found_reports drop constraint if exists found_photos_ok;
alter table public.found_reports add  constraint found_photos_ok  check (public.photo_urls_ok(photos)) not valid;
alter table public.sightings     drop constraint if exists sightings_photo_ok;
alter table public.sightings     add  constraint sightings_photo_ok check (public.photo_url_ok(photo_url)) not valid;
alter table public.pets          drop constraint if exists pets_photos_ok;
alter table public.pets          add  constraint pets_photos_ok   check (public.photo_urls_ok(photos)) not valid;

-- 2. 附近走失通知：排除隱藏案件 ------------------------------------------
create or replace function public.nearby_targets(p_hours integer default 26)
returns table(user_id uuid, email text, case_id uuid, case_name text, species text, lost_city text,
              lost_district text, lost_place text, distance_km double precision)
language sql stable security definer set search_path = public, auth as $$
  select p.id, u.email::text, c.id, c.name, c.species, c.lost_city, c.lost_district, c.lost_place,
         6371 * 2 * asin(sqrt(power(sin(radians(c.lost_lat - p.home_lat)/2),2) +
           cos(radians(p.home_lat)) * cos(radians(c.lost_lat)) * power(sin(radians(c.lost_lng - p.home_lng)/2),2))) as d
  from public.profiles p
  join auth.users u on u.id = p.id
  join public.cases c on c.status = 'searching' and c.lost_lat is not null and not c.hidden
       and c.created_at > now() - make_interval(hours => p_hours)
       and (p.notify_species = 'all' or p.notify_species = c.species)
       and (c.owner_id is null or c.owner_id <> p.id)
  where p.notify_enabled and p.home_lat is not null and u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = p.id and l.kind = 'nearby' and l.ref_id = c.id)
    and 6371 * 2 * asin(sqrt(power(sin(radians(c.lost_lat - p.home_lat)/2),2) +
           cos(radians(p.home_lat)) * cos(radians(c.lost_lat)) * power(sin(radians(c.lost_lng - p.home_lng)/2),2))) <= p.home_radius_km;
$$;
grant execute on function public.nearby_targets(integer) to service_role;

-- 3. 健康提醒：台灣日期 ---------------------------------------------------
create or replace function public.due_targets()
returns table(user_id uuid, email text, record_id uuid, pet_name text, title text, next_due date)
language sql stable security definer set search_path = public, auth as $$
  select r.owner_id, u.email::text, r.id, p.name, r.title, r.next_due
  from public.pet_records r
  join public.pets p on p.id = r.pet_id
  join auth.users u on u.id = r.owner_id
  where r.next_due is not null and not r.done
    and r.next_due <= (now() at time zone 'Asia/Taipei')::date + 7
    and r.next_due >= (now() at time zone 'Asia/Taipei')::date - 30
    and u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = r.owner_id and l.kind = 'due' and l.ref_id = r.id);
$$;
grant execute on function public.due_targets() to service_role;

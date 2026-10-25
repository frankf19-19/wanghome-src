-- ============================================================
-- 汪回家 WangHome — 資料庫升級 v1.1
-- 在已安裝 schema.sql (v1.0) 的專案上執行；不會刪除既有資料，可重複執行。
-- 新安裝：先跑 schema.sql，再跑本檔。
-- 內容：
--   1. 拾獲通報 found_reports（路人撿到／看到疑似走失的狗）
--   2. 拾獲 ↔ 案件比對紀錄 found_matches（daily.py 寫入，用來寄通知）
--   3. 欄位長度限制、防灌水觸發器
-- ============================================================

-- ------------------------------------------------------------
-- 1. 拾獲通報
-- ------------------------------------------------------------
create table if not exists public.found_reports (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  kind            text not null default 'seen' check (kind in ('found','seen')),  -- found=已收留/送醫，seen=只是看到
  status          text not null default 'open' check (status in ('open','reunited','closed')),
  seen_at         timestamptz not null,
  city            text not null,
  district        text,
  place_text      text,
  lat             double precision,
  lng             double precision,
  breed           text,
  sex             text check (sex in ('male','female','unknown')),
  size            text check (size in ('small','medium','large')),
  colour          text,
  features        text,
  collar_desc     text,
  current_place   text,             -- 狗目前在哪：我家／XX動物醫院／已送收容所／還在原地
  photos          text[] default '{}',
  reporter_name   text,
  reporter_phone  text,
  phone_public    boolean default true,
  reporter_email  text,             -- 私密
  reporter_line   text,
  notes           text,
  edit_token      text not null,
  constraint fr_len check (
    char_length(coalesce(place_text,''))   <= 200 and
    char_length(coalesce(features,''))     <= 1000 and
    char_length(coalesce(notes,''))        <= 1000 and
    char_length(coalesce(colour,''))       <= 50 and
    char_length(coalesce(breed,''))        <= 50 and
    char_length(coalesce(collar_desc,''))  <= 200 and
    char_length(coalesce(current_place,''))<= 200 and
    char_length(coalesce(reporter_name,''))<= 50 and
    coalesce(array_length(photos,1),0)     <= 4
  )
);
create index if not exists found_status_idx on public.found_reports(status, seen_at desc);
create index if not exists found_city_idx   on public.found_reports(city);
alter table public.found_reports enable row level security;

create table if not exists public.found_matches (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  case_id     uuid not null references public.cases(id) on delete cascade,
  found_id    uuid not null references public.found_reports(id) on delete cascade,
  score       integer default 0,
  notified    boolean default false,
  unique (case_id, found_id)
);
alter table public.found_matches enable row level security;

-- 公開 view（隱藏 email、token、未公開電話）
create or replace view public.found_public with (security_invoker = false) as
select id, created_at, updated_at, kind, status, seen_at, city, district, place_text, lat, lng,
       breed, sex, size, colour, features, collar_desc, current_place, photos, reporter_name,
       case when phone_public then reporter_phone else null end as reporter_phone,
       phone_public, reporter_line, notes
from public.found_reports;
grant select on public.found_public to anon, authenticated;

-- 建立拾獲通報
create or replace function public.create_found(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_token text := encode(gen_random_bytes(18), 'hex');
  v_id uuid;
begin
  if coalesce(p->>'city','') = '' or p->>'seen_at' is null then raise exception '缺少必填欄位'; end if;
  if (select count(*) from public.found_reports where created_at > now() - interval '10 minutes') > 60 then
    raise exception '目前送出太頻繁，請稍後再試';
  end if;
  insert into public.found_reports (
    kind, seen_at, city, district, place_text, lat, lng, breed, sex, size, colour, features,
    collar_desc, current_place, photos, reporter_name, reporter_phone, phone_public, reporter_email,
    reporter_line, notes, edit_token
  ) values (
    coalesce(nullif(p->>'kind',''),'seen'), (p->>'seen_at')::timestamptz, p->>'city', p->>'district',
    p->>'place_text', (p->>'lat')::double precision, (p->>'lng')::double precision, p->>'breed',
    nullif(p->>'sex',''), nullif(p->>'size',''), p->>'colour', p->>'features', p->>'collar_desc',
    p->>'current_place',
    coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'photos','[]'::jsonb)) x), '{}'),
    p->>'reporter_name', p->>'reporter_phone', coalesce((p->>'phone_public')::boolean,true),
    p->>'reporter_email', p->>'reporter_line', p->>'notes', encode(digest(v_token,'sha256'),'hex')
  ) returning id into v_id;
  return jsonb_build_object('id', v_id, 'token', v_token);
end $$;

-- 拾獲者更新狀態（已物歸原主／結案）與目前位置
create or replace function public.update_found(p_id uuid, p_token text, p jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  update public.found_reports set
    status        = coalesce(nullif(p->>'status',''), status),
    current_place = coalesce(p->>'current_place', current_place),
    notes         = coalesce(p->>'notes', notes),
    reporter_phone= coalesce(p->>'reporter_phone', reporter_phone),
    phone_public  = coalesce((p->>'phone_public')::boolean, phone_public),
    updated_at    = now()
  where id = p_id and edit_token = encode(digest(p_token,'sha256'),'hex');
  if not found then raise exception '管理連結無效'; end if;
end $$;

create or replace function public.owner_found(p_id uuid, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.found_reports;
begin
  select * into r from public.found_reports
   where id = p_id and edit_token = encode(digest(p_token,'sha256'),'hex');
  if not found then raise exception '管理連結無效'; end if;
  return to_jsonb(r) - 'edit_token';
end $$;

grant execute on function public.create_found(jsonb) to anon, authenticated;
grant execute on function public.update_found(uuid,text,jsonb) to anon, authenticated;
grant execute on function public.owner_found(uuid,text) to anon, authenticated;

-- ------------------------------------------------------------
-- 2. 長度限制（既有表）
-- ------------------------------------------------------------
alter table public.cases drop constraint if exists cases_len;
alter table public.cases add constraint cases_len check (
  char_length(name) between 1 and 30 and
  char_length(coalesce(features,''))    <= 1000 and
  char_length(coalesce(notes,''))       <= 1000 and
  char_length(coalesce(lost_place,''))  <= 200 and
  char_length(coalesce(colour,''))      <= 50 and
  char_length(coalesce(breed,''))       <= 50 and
  char_length(coalesce(collar_desc,'')) <= 200 and
  char_length(coalesce(temperament,'')) <= 200 and
  char_length(coalesce(found_note,''))  <= 1000 and
  coalesce(array_length(photos,1),0)    <= 4 and
  coalesce(reward,0) between 0 and 10000000
);
alter table public.sightings drop constraint if exists sightings_len;
alter table public.sightings add constraint sightings_len check (
  char_length(coalesce(note,''))             <= 1000 and
  char_length(coalesce(place_text,''))       <= 200 and
  char_length(coalesce(reporter_name,''))    <= 50 and
  char_length(coalesce(reporter_contact,'')) <= 100 and
  char_length(coalesce(direction,''))        <= 20
);

-- ------------------------------------------------------------
-- 3. 防灌水：同一案件 10 分鐘內最多 30 筆目擊；全站 10 分鐘最多 30 筆新案件
-- ------------------------------------------------------------
create or replace function public.limit_sightings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.sightings where case_id = new.case_id and created_at > now() - interval '10 minutes') >= 30 then
    raise exception '這個案件短時間內回報太多次，請稍後再試';
  end if;
  new.status := 'pending';     -- 匿名送出一律待確認
  new.notified := false;
  return new;
end $$;
drop trigger if exists sightings_limit on public.sightings;
create trigger sightings_limit before insert on public.sightings
  for each row execute function public.limit_sightings();

create or replace function public.limit_cases() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.cases where created_at > now() - interval '10 minutes') >= 30 then
    raise exception '目前登記太頻繁，請稍後再試';
  end if;
  return new;
end $$;
drop trigger if exists cases_limit on public.cases;
create trigger cases_limit before insert on public.cases
  for each row execute function public.limit_cases();

-- ------------------------------------------------------------
-- 4. 最新目擊動態（首頁用；只含已確認、協尋中案件）
-- ------------------------------------------------------------
create or replace view public.recent_sightings with (security_invoker = false) as
select s.id, s.case_id, s.seen_at, s.place_text, s.direction, s.photo_url,
       c.name as case_name, c.lost_city, c.lost_district, c.photos[1] as case_photo
from public.sightings s join public.cases c on c.id = s.case_id
where s.status = 'confirmed' and c.status = 'searching'
order by s.seen_at desc
limit 20;
grant select on public.recent_sightings to anon, authenticated;

-- 後台權限
grant all on public.found_reports, public.found_matches to service_role;
grant all on all functions in schema public to service_role;

select 'WangHome migration v1.1 installed' as result;

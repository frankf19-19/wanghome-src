-- ============================================================
-- 汪回家 WangHome — Supabase 資料庫結構  v1.0.0
-- 使用方式：Supabase Dashboard → SQL Editor → New query → 貼上全部 → Run
-- 可重複執行（會先刪除舊物件再建立）
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 0. 清除舊物件（重新執行時用）
-- ------------------------------------------------------------
drop view if exists public.cases_public cascade;
drop view if exists public.sightings_public cascade;
drop view if exists public.sponsors_public cascade;
drop function if exists public.create_case(jsonb) cascade;
drop function if exists public.update_case(uuid, text, jsonb) cascade;
drop function if exists public.owner_case(uuid, text) cascade;
drop function if exists public.owner_sightings(uuid, text) cascade;
drop function if exists public.set_sighting_status(uuid, uuid, text, text) cascade;
drop function if exists public.dismiss_match(uuid, uuid, text) cascade;
drop function if exists public.touch_case_activity() cascade;
drop table if exists public.shelter_matches cascade;
drop table if exists public.sightings cascade;
drop table if exists public.sponsors cascade;
drop table if exists public.cases cascade;

-- ------------------------------------------------------------
-- 1. 走失案件
-- ------------------------------------------------------------
create table public.cases (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  last_activity   timestamptz not null default now(),   -- 有新目擊/更新時刷新，用來排序
  status          text not null default 'searching'     -- searching / found / closed
                  check (status in ('searching','found','closed')),
  name            text not null,                        -- 狗名
  species         text not null default 'dog',          -- 先只做狗，保留欄位
  breed           text,
  sex             text check (sex in ('male','female','unknown')),
  size            text check (size in ('small','medium','large')),
  colour          text,                                 -- 毛色（自由文字）
  age_text        text,                                 -- 例「10歲以上」
  features        text,                                 -- 特徵描述
  has_chip        boolean default false,
  chip_last4      text,                                 -- 晶片末四碼（公開）
  neutered        boolean,
  collar_desc     text,                                 -- 走失時項圈/牽繩
  temperament     text,                                 -- 親人/膽小/會咬
  lost_at         timestamptz not null,
  lost_city       text not null,
  lost_district   text,
  lost_place      text,                                 -- 地點描述
  lost_lat        double precision,
  lost_lng        double precision,
  photos          text[] default '{}',                  -- storage 公開網址
  contact_name    text,
  contact_phone   text,
  phone_public    boolean default true,
  contact_email   text,                                 -- 私密，用來寄通知
  contact_line    text,
  reward          integer default 0,                    -- 尋獲獎金（0=無）
  notes           text,
  edit_token      text not null,                        -- 飼主管理用（sha256）
  found_at        timestamptz,
  found_note      text,                                 -- 在哪裡怎麼找到的（結案回報）
  found_method    text,                                 -- 找回方式（統計用）
  view_count      integer default 0
);
create index cases_status_idx   on public.cases(status);
create index cases_city_idx     on public.cases(lost_city);
create index cases_activity_idx on public.cases(last_activity desc);

-- ------------------------------------------------------------
-- 2. 目擊回報
-- ------------------------------------------------------------
create table public.sightings (
  id               uuid primary key default gen_random_uuid(),
  case_id          uuid not null references public.cases(id) on delete cascade,
  created_at       timestamptz not null default now(),
  seen_at          timestamptz not null,
  lat              double precision,
  lng              double precision,
  place_text       text,
  direction        text,          -- 移動方向
  note             text,
  photo_url        text,
  reporter_name    text,
  reporter_contact text,          -- 私密，只有飼主看得到
  status           text not null default 'pending'
                   check (status in ('pending','confirmed','rejected')),
  owner_note       text,          -- 飼主備註
  notified         boolean default false  -- 是否已寄通知給飼主
);
create index sightings_case_idx on public.sightings(case_id, seen_at desc);
create index sightings_notify_idx on public.sightings(notified) where notified = false;

-- ------------------------------------------------------------
-- 3. 收容所自動比對結果（由 GitHub Actions 寫入）
-- ------------------------------------------------------------
create table public.shelter_matches (
  id               uuid primary key default gen_random_uuid(),
  case_id          uuid not null references public.cases(id) on delete cascade,
  matched_at       timestamptz not null default now(),
  animal_id        text not null,
  animal_subid     text,
  shelter_name     text,
  shelter_tel      text,
  shelter_address  text,
  found_place      text,
  colour           text,
  bodytype         text,
  sex              text,
  age              text,
  variety          text,
  photo_url        text,
  open_date        date,
  score            integer default 0,    -- 相似度分數
  dismissed        boolean default false,
  notified         boolean default false,
  unique (case_id, animal_id)
);
create index matches_case_idx on public.shelter_matches(case_id);

-- ------------------------------------------------------------
-- 4. 贊助感謝牆（由站長在 Dashboard Table Editor 手動新增）
-- ------------------------------------------------------------
create table public.sponsors (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  sponsored_on date not null default current_date,
  nickname     text not null,
  message      text,
  amount       integer,
  show_amount  boolean default false,
  visible      boolean default true
);

-- ------------------------------------------------------------
-- 5. 觸發器：目擊/更新時刷新 last_activity
-- ------------------------------------------------------------
create function public.touch_case_activity() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.cases set last_activity = now(), updated_at = now()
   where id = coalesce(new.case_id, old.case_id);
  return new;
end $$;
create trigger sightings_touch after insert or update on public.sightings
  for each row execute function public.touch_case_activity();
create trigger matches_touch after insert on public.shelter_matches
  for each row execute function public.touch_case_activity();

-- ------------------------------------------------------------
-- 6. 公開 View（過濾私密欄位）
-- ------------------------------------------------------------
create view public.cases_public with (security_invoker = false) as
select id, created_at, updated_at, last_activity, status, name, species, breed, sex, size,
       colour, age_text, features, has_chip, chip_last4, neutered, collar_desc, temperament,
       lost_at, lost_city, lost_district, lost_place, lost_lat, lost_lng, photos,
       contact_name,
       case when phone_public then contact_phone else null end as contact_phone,
       phone_public, contact_line, reward, notes, found_at, found_note, found_method, view_count,
       (select count(*) from public.sightings s where s.case_id = c.id and s.status='confirmed') as sighting_count,
       (select max(seen_at) from public.sightings s where s.case_id = c.id and s.status='confirmed') as last_seen_at
from public.cases c;

create view public.sightings_public with (security_invoker = false) as
select id, case_id, created_at, seen_at, lat, lng, place_text, direction, note, photo_url,
       reporter_name, status, owner_note
from public.sightings where status = 'confirmed';

create view public.sponsors_public with (security_invoker = false) as
select id, sponsored_on, nickname, message,
       case when show_amount then amount else null end as amount
from public.sponsors where visible = true
order by sponsored_on desc, created_at desc;

grant select on public.cases_public, public.sightings_public, public.sponsors_public to anon, authenticated;
grant select on public.shelter_matches to anon, authenticated;   -- 收容所資料本來就是公開的

-- ------------------------------------------------------------
-- 7. RLS
-- ------------------------------------------------------------
alter table public.cases           enable row level security;
alter table public.sightings       enable row level security;
alter table public.shelter_matches enable row level security;
alter table public.sponsors        enable row level security;

-- 任何人可新增目擊（透過前端表單），但不能直接讀底層表
create policy "anon insert sighting" on public.sightings
  for insert to anon, authenticated with check (true);
grant insert on public.sightings to anon, authenticated;

create policy "public read matches" on public.shelter_matches
  for select to anon, authenticated using (true);

-- cases / sponsors 底層表不開放 anon 直接存取，全部走 view 與 RPC

-- ------------------------------------------------------------
-- 8. RPC（security definer，用 token 驗證飼主身分）
-- ------------------------------------------------------------

-- 建立案件：回傳 id 與明文 token（只會出現這一次，前端要提醒飼主保存）
create function public.create_case(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_token text := encode(gen_random_bytes(18), 'hex');
  v_id uuid;
begin
  if coalesce(p->>'name','') = '' or coalesce(p->>'lost_city','') = '' or p->>'lost_at' is null then
    raise exception '缺少必填欄位';
  end if;
  insert into public.cases (
    name, breed, sex, size, colour, age_text, features, has_chip, chip_last4, neutered,
    collar_desc, temperament, lost_at, lost_city, lost_district, lost_place, lost_lat, lost_lng,
    photos, contact_name, contact_phone, phone_public, contact_email, contact_line, reward, notes, edit_token
  ) values (
    p->>'name', p->>'breed', nullif(p->>'sex',''), nullif(p->>'size',''), p->>'colour', p->>'age_text',
    p->>'features', coalesce((p->>'has_chip')::boolean,false), p->>'chip_last4', (p->>'neutered')::boolean,
    p->>'collar_desc', p->>'temperament', (p->>'lost_at')::timestamptz, p->>'lost_city', p->>'lost_district',
    p->>'lost_place', (p->>'lost_lat')::double precision, (p->>'lost_lng')::double precision,
    coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'photos','[]'::jsonb)) x), '{}'),
    p->>'contact_name', p->>'contact_phone', coalesce((p->>'phone_public')::boolean,true),
    p->>'contact_email', p->>'contact_line', coalesce((p->>'reward')::integer,0), p->>'notes',
    encode(digest(v_token,'sha256'),'hex')
  ) returning id into v_id;
  return jsonb_build_object('id', v_id, 'token', v_token);
end $$;

-- 飼主讀取自己的完整案件（含私密欄位）
create function public.owner_case(p_id uuid, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.cases;
begin
  select * into r from public.cases
   where id = p_id and edit_token = encode(digest(p_token,'sha256'),'hex');
  if not found then raise exception '管理連結無效'; end if;
  return to_jsonb(r) - 'edit_token';
end $$;

-- 飼主更新案件（狀態、結案回報、補充資料…）
create function public.update_case(p_id uuid, p_token text, p jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
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
  where id = p_id and edit_token = encode(digest(p_token,'sha256'),'hex');
  if not found then raise exception '管理連結無效'; end if;
end $$;

-- 飼主看全部目擊（含待確認、含回報者聯絡方式）
create function public.owner_sightings(p_id uuid, p_token text)
returns setof public.sightings language sql security definer set search_path = public, extensions as $$
  select s.* from public.sightings s
  join public.cases c on c.id = s.case_id
  where c.id = p_id and c.edit_token = encode(digest(p_token,'sha256'),'hex')
  order by s.seen_at desc;
$$;

-- 飼主確認/退回目擊
create function public.set_sighting_status(p_case uuid, p_sighting uuid, p_token text, p_status text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_status not in ('pending','confirmed','rejected') then raise exception '狀態錯誤'; end if;
  update public.sightings s set status = p_status
   from public.cases c
  where s.id = p_sighting and s.case_id = p_case and c.id = s.case_id
    and c.edit_token = encode(digest(p_token,'sha256'),'hex');
  if not found then raise exception '管理連結無效'; end if;
end $$;

-- 飼主忽略某筆收容所比對
create function public.dismiss_match(p_case uuid, p_match uuid, p_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  update public.shelter_matches m set dismissed = true
   from public.cases c
  where m.id = p_match and m.case_id = p_case and c.id = m.case_id
    and c.edit_token = encode(digest(p_token,'sha256'),'hex');
  if not found then raise exception '管理連結無效'; end if;
end $$;

-- 瀏覽次數 +1（任何人可呼叫）
create or replace function public.bump_view(p_id uuid) returns void
language sql security definer set search_path = public, extensions as $$
  update public.cases set view_count = view_count + 1 where id = p_id;
$$;

grant execute on function public.create_case(jsonb) to anon, authenticated;
grant execute on function public.owner_case(uuid,text) to anon, authenticated;
grant execute on function public.update_case(uuid,text,jsonb) to anon, authenticated;
grant execute on function public.owner_sightings(uuid,text) to anon, authenticated;
grant execute on function public.set_sighting_status(uuid,uuid,text,text) to anon, authenticated;
grant execute on function public.dismiss_match(uuid,uuid,text) to anon, authenticated;
grant execute on function public.bump_view(uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- 9. Storage：照片 bucket（公開讀取、任何人可上傳、限 5MB 圖片）
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "public read photos"   on storage.objects;
drop policy if exists "anon upload photos"   on storage.objects;
create policy "public read photos" on storage.objects for select to anon, authenticated
  using (bucket_id = 'photos');
create policy "anon upload photos" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'photos');

-- ------------------------------------------------------------
-- 10. 找回方式統計（公開）
-- ------------------------------------------------------------
create or replace view public.found_stats with (security_invoker = false) as
select found_method, count(*) as n
from public.cases where status = 'found' and found_method is not null
group by found_method order by n desc;
grant select on public.found_stats to anon, authenticated;

-- ------------------------------------------------------------
-- 11. 後台腳本（GitHub Actions 用 service_role）需要完整權限
--     （專案若關閉「Automatically expose new tables」就必須明確授權）
-- ------------------------------------------------------------
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
grant all on all functions in schema public to service_role;

-- 完成
select 'WangHome schema v1.0.0 installed' as result;

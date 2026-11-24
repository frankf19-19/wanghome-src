-- 汪喵回家 migration v1.98 — 健康手冊專業版（第一期：飼主端）
--   1. 健康紀錄可以照動物醫院病歷的格式記：生命徵象、主訴、理學檢查、診斷、治療計畫、處方、檢驗數值、疫苗批號（pet_records.pro）
--   2. 附件照片分類：病歷摘要、診斷書、檢驗報告、影像、處方、收據…（pet_records.doc_kinds，和 files 一一對應）
--   3. 毛孩檔案多了過敏、慢性病／病史、血型（pets）
--   4. 急診／換醫院用的一頁摘要：飼主產生分享碼（30 天有效、可隨時停止），獸醫用連結就能看（pet_shares、pet_share_get）
--   5. 協尋案件可以加「健康提醒」（選填、公開），撿到的人知道要盡快送醫（cases.health_alert、set_health_alert）

-- 1、2：健康紀錄
alter table public.pet_records add column if not exists pro jsonb not null default '{}'::jsonb;
alter table public.pet_records add column if not exists doc_kinds text[] not null default '{}';
alter table public.pet_records drop constraint if exists pet_records_pro_chk;
alter table public.pet_records add constraint pet_records_pro_chk check (
  jsonb_typeof(pro) = 'object' and pg_column_size(pro) < 24000 and coalesce(array_length(doc_kinds,1),0) <= 6
  and doc_kinds <@ array['summary','diagnosis','lab','imaging','rx','receipt','vaccine','other']::text[]);

-- 3：毛孩檔案的健康欄位
alter table public.pets add column if not exists allergies  text;
alter table public.pets add column if not exists conditions text;
alter table public.pets add column if not exists blood_type text;
alter table public.pets drop constraint if exists pets_health_len;
alter table public.pets add constraint pets_health_len check (
  char_length(coalesce(allergies,'')) <= 300 and char_length(coalesce(conditions,'')) <= 600 and char_length(coalesce(blood_type,'')) <= 20);

-- 4：一頁摘要分享
create table if not exists public.pet_shares (
  id         uuid primary key default gen_random_uuid(),
  pet_id     uuid not null references public.pets(id) on delete cascade,
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  code       text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  views      integer not null default 0
);
create index if not exists pet_shares_pet on public.pet_shares(pet_id);
alter table public.pet_shares enable row level security;
drop policy if exists pet_shares_own on public.pet_shares;
create policy pet_shares_own on public.pet_shares for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
grant select, delete on public.pet_shares to authenticated;

-- 產生分享碼（只能幫自己的毛孩產生；同一隻只留最新一個有效的碼）
create or replace function public.pet_share_create(p_pet uuid, p_days integer default 30)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_code text; v_exp timestamptz := now() + make_interval(days => greatest(1, least(coalesce(p_days,30), 90)));
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if not exists (select 1 from public.pets where id = p_pet and owner_id = auth.uid()) then raise exception '找不到這隻毛孩'; end if;
  delete from public.pet_shares where pet_id = p_pet;
  v_code := translate(encode(gen_random_bytes(9), 'base64'), '+/=', 'xyz');
  insert into public.pet_shares (pet_id, owner_id, code, expires_at) values (p_pet, auth.uid(), v_code, v_exp);
  return jsonb_build_object('code', v_code, 'expires_at', v_exp);
end $$;
revoke all on function public.pet_share_create(uuid, integer) from public, anon;
grant execute on function public.pet_share_create(uuid, integer) to authenticated;

-- 獸醫用分享碼讀一頁摘要（不需要登入；只給看診需要的資料，不含飼主個資、不含私密照片）
create or replace function public.pet_share_get(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s record; p record; out jsonb;
begin
  select * into s from public.pet_shares where code = p_code and expires_at > now();
  if not found then return null; end if;
  update public.pet_shares set views = views + 1 where id = s.id;
  select * into p from public.pets where id = s.pet_id;
  if not found then return null; end if;
  out := jsonb_build_object(
    'pet', jsonb_build_object('name', p.name, 'species', p.species, 'breed', p.breed, 'sex', p.sex, 'colour', p.colour,
           'birthday', p.birthday, 'age_text', p.age_text, 'neutered', p.neutered, 'has_chip', p.has_chip, 'chip_no', p.chip_no,
           'allergies', p.allergies, 'conditions', p.conditions, 'blood_type', p.blood_type, 'notes', p.notes,
           'photo', (p.photos)[1]),
    'meds', coalesce((select jsonb_agg(jsonb_build_object('name', m.name, 'kind', m.kind, 'dose_amount', m.dose_amount, 'dose_unit', m.dose_unit,
           'freq', m.freq, 'times', m.times, 'start_date', m.start_date, 'end_date', m.end_date, 'purpose', m.purpose, 'clinic', m.clinic) order by m.kind, m.created_at)
           from public.pet_meds m where m.pet_id = p.id and m.active), '[]'::jsonb),
    'records', coalesce((select jsonb_agg(jsonb_build_object('date', r.date, 'kind', r.kind, 'title', r.title, 'clinic', r.clinic,
           'weight_kg', r.weight_kg, 'notes', r.notes, 'next_due', r.next_due, 'done', r.done, 'pro', r.pro) order by r.date desc, r.created_at desc)
           from (select * from public.pet_records r where r.pet_id = p.id and r.kind <> 'grooming' order by r.date desc, r.created_at desc limit 60) r), '[]'::jsonb),
    'expires_at', s.expires_at, 'generated_at', now());
  return out;
end $$;
revoke all on function public.pet_share_get(text) from public;
grant execute on function public.pet_share_get(text) to anon, authenticated;

-- 5：協尋案件的健康提醒（公開）
alter table public.cases add column if not exists health_alert text;
alter table public.cases drop constraint if exists cases_health_alert_len;
alter table public.cases add constraint cases_health_alert_len check (char_length(coalesce(health_alert,'')) <= 200);

create or replace view public.cases_public with (security_invoker = false) as
select id, created_at, updated_at, last_activity, status, name, species, breed, sex, size,
       colour, age_text, features, has_chip, chip_last4, neutered, collar_desc, temperament,
       lost_at, lost_city, lost_district, lost_place, lost_lat, lost_lng, photos,
       contact_name,
       case when phone_public then contact_phone else null end as contact_phone,
       phone_public, contact_line, reward, notes, found_at, found_note, found_method, view_count,
       (select count(*) from public.sightings s where s.case_id = c.id and s.status='confirmed') as sighting_count,
       (select max(seen_at) from public.sightings s where s.case_id = c.id and s.status='confirmed') as last_seen_at,
       left(md5('wm-poster:' || coalesce(c.owner_id::text, 'c:' || c.id::text)), 12) as poster,
       (select count(*) from public.sightings s where s.case_id = c.id and s.status = 'pending' and s.status_before_hide is null) as pending_count,
       c.source,
       c.found_photo,
       c.health_alert
from public.cases c
where not c.hidden;

create or replace function public.set_health_alert(p_case uuid, p_token text, p_text text)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.can_manage_case(p_case, p_token) then return false; end if;
  update public.cases set health_alert = nullif(left(btrim(coalesce(p_text,'')), 200), ''), updated_at = now() where id = p_case;
  get diagnostics n = row_count;
  return n > 0;
end $$;
revoke all on function public.set_health_alert(uuid, text, text) from public;
grant execute on function public.set_health_alert(uuid, text, text) to anon, authenticated;

select 'WangMiao migration v1.98 installed' as result;

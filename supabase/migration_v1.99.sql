-- 汪喵回家 migration v1.99 — 健康手冊專業版（第二期：動物醫院端）
--   1. 動物醫院申請帳號：填醫院資料、上傳開業執照與獸醫師證書（私密空間 clinic-docs），站長在管理後台審核通過才能開病歷
--   2. 飼主產生「醫院連結碼」（15 分鐘有效、只能用一次）→ 醫院掃碼或輸入 → 這家醫院可以幫這隻毛孩開病歷；飼主可以隨時取消
--   3. 醫院開的病歷（clinic_visits）：符合獸醫師法第 12 條要記載的事項（飼主姓名地址、動物種類體重、日期、發病情形、診斷、用藥治療、管制藥品）
--      飼主在健康手冊看得到（唯讀）；醫院可以列印病歷摘要
--   4. 看診摘要分享（pet_share_get）也一起帶入醫院開的病歷

-- 1. 動物醫院
create table if not exists public.clinics (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  name          text not null,
  city          text,
  address       text not null,
  phone         text not null,
  license_no    text not null,          -- 動物診療機構開業執照字號
  vet_name      text not null,          -- 負責獸醫師
  vet_license   text not null,          -- 獸醫師證書字號
  docs          text[] not null default '{}',   -- 執照照片（clinic-docs 私密路徑）
  status        text not null default 'pending' check (status in ('pending','approved','rejected','suspended')),
  review_note   text,
  reviewed_at   timestamptz,
  constraint clinics_len check (char_length(name) between 2 and 60 and char_length(address) between 4 and 120 and char_length(phone) between 6 and 30
    and char_length(license_no) between 2 and 60 and char_length(vet_name) between 1 and 30 and char_length(vet_license) between 2 and 60
    and char_length(coalesce(city,'')) <= 10 and coalesce(array_length(docs,1),0) between 0 and 4 and char_length(coalesce(review_note,'')) <= 300)
);
create unique index if not exists clinics_owner_one on public.clinics(owner_id);
alter table public.clinics enable row level security;
drop policy if exists clinics_own_read on public.clinics;
create policy clinics_own_read on public.clinics for select to authenticated using (owner_id = auth.uid() or public.is_admin());
grant select on public.clinics to authenticated;

-- 申請／修改醫院資料（修改後要重新審核）
create or replace function public.clinic_apply(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_docs text[];
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  v_docs := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'docs','[]'::jsonb)) x where x like auth.uid()::text || '/%'), '{}');
  if coalesce(array_length(v_docs,1),0) = 0 then raise exception '請上傳開業執照照片'; end if;
  insert into public.clinics (owner_id, name, city, address, phone, license_no, vet_name, vet_license, docs, status)
  values (auth.uid(), btrim(p->>'name'), nullif(btrim(coalesce(p->>'city','')),''), btrim(p->>'address'), btrim(p->>'phone'),
          btrim(p->>'license_no'), btrim(p->>'vet_name'), btrim(p->>'vet_license'), v_docs, 'pending')
  on conflict (owner_id) do update set name = excluded.name, city = excluded.city, address = excluded.address, phone = excluded.phone,
    license_no = excluded.license_no, vet_name = excluded.vet_name, vet_license = excluded.vet_license, docs = excluded.docs,
    status = case when public.clinics.status = 'suspended' then 'suspended' else 'pending' end, review_note = null, updated_at = now()
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.clinic_apply(jsonb) from public, anon;
grant execute on function public.clinic_apply(jsonb) to authenticated;

-- 目前登入的人是哪一家「已通過」的醫院
create or replace function public.my_clinic_id() returns uuid language sql stable security definer set search_path = public as $$
  select id from public.clinics where owner_id = auth.uid() and status = 'approved' $$;
grant execute on function public.my_clinic_id() to authenticated;

-- 站長審核
create or replace function public.admin_clinic_review(p_id uuid, p_status text, p_note text default null)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_status not in ('approved','rejected','suspended','pending') then raise exception '狀態不對'; end if;
  update public.clinics set status = p_status, review_note = nullif(left(btrim(coalesce(p_note,'')),300),''), reviewed_at = now(), updated_at = now() where id = p_id;
  return found;
end $$;
revoke all on function public.admin_clinic_review(uuid, text, text) from public, anon;
grant execute on function public.admin_clinic_review(uuid, text, text) to authenticated;

-- 執照照片：私密空間，路徑第一層是申請人自己的 id；站長看得到
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('clinic-docs', 'clinic-docs', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists "clinic docs own write" on storage.objects;
drop policy if exists "clinic docs own read" on storage.objects;
drop policy if exists "clinic docs own delete" on storage.objects;
create policy "clinic docs own write" on storage.objects for insert to authenticated
  with check (bucket_id = 'clinic-docs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "clinic docs own read" on storage.objects for select to authenticated
  using (bucket_id = 'clinic-docs' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "clinic docs own delete" on storage.objects for delete to authenticated
  using (bucket_id = 'clinic-docs' and (storage.foldername(name))[1] = auth.uid()::text);

-- 2. 飼主授權醫院
create table if not exists public.pet_clinic_links (
  pet_id     uuid not null references public.pets(id) on delete cascade,
  clinic_id  uuid not null references public.clinics(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (pet_id, clinic_id)
);
alter table public.pet_clinic_links enable row level security;
drop policy if exists pcl_read on public.pet_clinic_links;
create policy pcl_read on public.pet_clinic_links for select to authenticated
  using (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid()) or clinic_id = public.my_clinic_id());
drop policy if exists pcl_owner_delete on public.pet_clinic_links;
create policy pcl_owner_delete on public.pet_clinic_links for delete to authenticated
  using (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid()));
grant select, delete on public.pet_clinic_links to authenticated;

create table if not exists public.pet_link_codes (
  code       text primary key,
  pet_id     uuid not null references public.pets(id) on delete cascade,
  owner_id   uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '15 minutes'
);
alter table public.pet_link_codes enable row level security;   -- 只能透過下面的函式使用

create or replace function public.pet_link_code(p_pet uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_code text; v_exp timestamptz := now() + interval '15 minutes';
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if not exists (select 1 from public.pets where id = p_pet and owner_id = auth.uid()) then raise exception '找不到這隻毛孩'; end if;
  delete from public.pet_link_codes where pet_id = p_pet or expires_at < now();
  loop
    v_code := upper(substr(translate(encode(gen_random_bytes(8), 'base64'), '+/=0O1IL', ''), 1, 6));
    exit when length(v_code) = 6 and not exists (select 1 from public.pet_link_codes where code = v_code);
  end loop;
  insert into public.pet_link_codes (code, pet_id, owner_id, expires_at) values (v_code, p_pet, auth.uid(), v_exp);
  return jsonb_build_object('code', v_code, 'expires_at', v_exp);
end $$;
revoke all on function public.pet_link_code(uuid) from public, anon;
grant execute on function public.pet_link_code(uuid) to authenticated;

-- 醫院用連結碼連結毛孩（碼只能用一次）
create or replace function public.clinic_link_pet(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_clinic uuid := public.my_clinic_id(); v_pet uuid;
begin
  if v_clinic is null then raise exception '醫院帳號還沒通過審核'; end if;
  delete from public.pet_link_codes where code = upper(btrim(p_code)) and expires_at > now() returning pet_id into v_pet;
  if v_pet is null then raise exception '連結碼不對或已經過期，請飼主重新產生'; end if;
  insert into public.pet_clinic_links (pet_id, clinic_id) values (v_pet, v_clinic) on conflict do nothing;
  return v_pet;
end $$;
revoke all on function public.clinic_link_pet(text) from public, anon;
grant execute on function public.clinic_link_pet(text) to authenticated;

-- 3. 醫院開的病歷
create table if not exists public.clinic_visits (
  id            uuid primary key default gen_random_uuid(),
  clinic_id     uuid not null references public.clinics(id) on delete restrict,
  pet_id        uuid references public.pets(id) on delete set null,     -- 飼主刪掉毛孩檔案，醫院的病歷照樣保留
  created_by    uuid not null default auth.uid() references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  visit_date    date not null default current_date,
  title         text not null,
  vet_name      text not null,
  owner_name    text not null,
  owner_address text not null,
  pet_name      text not null,
  species       text not null default 'dog',
  breed         text,
  weight_kg     numeric(5,2) check (weight_kg is null or (weight_kg > 0 and weight_kg < 200)),
  pro           jsonb not null default '{}'::jsonb,
  notes         text,
  next_due      date,
  next_due_note text,
  shared        boolean not null default true,     -- 傳給飼主的健康手冊
  constraint clinic_visits_len check (char_length(title) between 1 and 60 and char_length(vet_name) between 1 and 30
    and char_length(owner_name) between 1 and 30 and char_length(owner_address) between 2 and 120 and char_length(pet_name) between 1 and 30
    and char_length(coalesce(breed,'')) <= 50 and char_length(coalesce(notes,'')) <= 2000 and char_length(coalesce(next_due_note,'')) <= 60
    and jsonb_typeof(pro) = 'object' and pg_column_size(pro) < 24000)
);
create index if not exists clinic_visits_pet on public.clinic_visits(pet_id, visit_date desc);
create index if not exists clinic_visits_clinic on public.clinic_visits(clinic_id, visit_date desc);
alter table public.clinic_visits enable row level security;
drop policy if exists cv_read on public.clinic_visits;
create policy cv_read on public.clinic_visits for select to authenticated
  using (clinic_id = public.my_clinic_id() or (shared and exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid())));
drop policy if exists cv_clinic_insert on public.clinic_visits;
create policy cv_clinic_insert on public.clinic_visits for insert to authenticated
  with check (clinic_id = public.my_clinic_id() and created_by = auth.uid()
    and exists (select 1 from public.pet_clinic_links l where l.pet_id = clinic_visits.pet_id and l.clinic_id = clinic_visits.clinic_id));
drop policy if exists cv_clinic_update on public.clinic_visits;
create policy cv_clinic_update on public.clinic_visits for update to authenticated
  using (clinic_id = public.my_clinic_id()) with check (clinic_id = public.my_clinic_id());
grant select, insert, update on public.clinic_visits to authenticated;

-- 醫院讀已授權毛孩的基本資料與飼主自己記的重點（過敏、慢性病、目前用藥）
create or replace function public.clinic_pets()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'species', p.species, 'breed', p.breed, 'sex', p.sex,
           'photo', (p.photos)[1], 'linked_at', l.created_at,
           'last_visit', (select max(v.visit_date) from public.clinic_visits v where v.pet_id = p.id and v.clinic_id = l.clinic_id)) order by l.created_at desc), '[]'::jsonb)
  from public.pet_clinic_links l join public.pets p on p.id = l.pet_id where l.clinic_id = public.my_clinic_id() $$;
grant execute on function public.clinic_pets() to authenticated;

create or replace function public.clinic_pet(p_pet uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_clinic uuid := public.my_clinic_id(); p record;
begin
  if v_clinic is null or not exists (select 1 from public.pet_clinic_links where pet_id = p_pet and clinic_id = v_clinic) then return null; end if;
  select * into p from public.pets where id = p_pet;
  return jsonb_build_object('pet', jsonb_build_object('id', p.id, 'name', p.name, 'species', p.species, 'breed', p.breed, 'sex', p.sex, 'colour', p.colour,
           'birthday', p.birthday, 'age_text', p.age_text, 'neutered', p.neutered, 'has_chip', p.has_chip, 'chip_no', p.chip_no,
           'allergies', p.allergies, 'conditions', p.conditions, 'blood_type', p.blood_type, 'notes', p.notes, 'photo', (p.photos)[1]),
    'meds', coalesce((select jsonb_agg(jsonb_build_object('name', m.name, 'kind', m.kind, 'dose_amount', m.dose_amount, 'dose_unit', m.dose_unit,
           'freq', m.freq, 'times', m.times, 'start_date', m.start_date, 'purpose', m.purpose) order by m.kind, m.created_at)
           from public.pet_meds m where m.pet_id = p.id and m.active), '[]'::jsonb),
    'weight', (select jsonb_build_object('kg', r.weight_kg, 'date', r.date) from public.pet_records r where r.pet_id = p.id and r.weight_kg is not null order by r.date desc limit 1));
end $$;
grant execute on function public.clinic_pet(uuid) to authenticated;

-- 飼主看自己毛孩授權了哪些醫院（含醫院名稱）
create or replace function public.pet_clinics(p_pet uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('clinic_id', c.id, 'name', c.name, 'city', c.city, 'linked_at', l.created_at) order by l.created_at desc), '[]'::jsonb)
  from public.pet_clinic_links l join public.clinics c on c.id = l.clinic_id
  where l.pet_id = p_pet and exists (select 1 from public.pets p where p.id = p_pet and p.owner_id = auth.uid()) $$;
grant execute on function public.pet_clinics(uuid) to authenticated;

-- 飼主讀醫院開的病歷（帶醫院名稱、電話）
create or replace function public.pet_clinic_visits(p_pet uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(v) - 'created_by' || jsonb_build_object('clinic_name', c.name, 'clinic_phone', c.phone, 'clinic_address', c.address, 'clinic_license', c.license_no)
           order by v.visit_date desc, v.created_at desc), '[]'::jsonb)
  from public.clinic_visits v join public.clinics c on c.id = v.clinic_id
  where v.pet_id = p_pet and v.shared and exists (select 1 from public.pets p where p.id = p_pet and p.owner_id = auth.uid()) $$;
grant execute on function public.pet_clinic_visits(uuid) to authenticated;

-- 醫院讀自己開的病歷（列印用，帶醫院抬頭）
create or replace function public.clinic_visit_get(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(v) || jsonb_build_object('clinic_name', c.name, 'clinic_phone', c.phone, 'clinic_address', c.address, 'clinic_license', c.license_no)
  from public.clinic_visits v join public.clinics c on c.id = v.clinic_id
  where v.id = p_id and (v.clinic_id = public.my_clinic_id() or (v.shared and exists (select 1 from public.pets p where p.id = v.pet_id and p.owner_id = auth.uid()))) $$;
grant execute on function public.clinic_visit_get(uuid) to authenticated;

-- 管理後台：醫院申請列表
create or replace function public.admin_clinics()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('username', pr.username,
           'visits', (select count(*) from public.clinic_visits v where v.clinic_id = c.id),
           'pets', (select count(*) from public.pet_clinic_links l where l.clinic_id = c.id))
         order by (c.status = 'pending') desc, c.updated_at desc)
         from public.clinics c left join public.profiles pr on pr.id = c.owner_id), '[]'::jsonb);
end $$;
grant execute on function public.admin_clinics() to authenticated;

-- 4. 看診摘要分享：一起帶入醫院開的病歷
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
    'records', coalesce((select jsonb_agg(x order by x->>'date' desc) from (
           (select jsonb_build_object('date', r.date, 'kind', r.kind, 'title', r.title, 'clinic', r.clinic,
             'weight_kg', r.weight_kg, 'notes', r.notes, 'next_due', r.next_due, 'done', r.done, 'pro', r.pro) as x
            from public.pet_records r where r.pet_id = p.id and r.kind <> 'grooming' order by r.date desc, r.created_at desc limit 60)
           union all
           (select jsonb_build_object('date', v.visit_date, 'kind', 'vet', 'title', v.title, 'clinic', c.name, 'verified', true,
             'weight_kg', v.weight_kg, 'notes', v.notes, 'next_due', v.next_due, 'done', false, 'pro', v.pro || jsonb_build_object('vet', v.vet_name)) as x
            from public.clinic_visits v join public.clinics c on c.id = v.clinic_id where v.pet_id = p.id and v.shared order by v.visit_date desc limit 30)) q), '[]'::jsonb),
    'expires_at', s.expires_at, 'generated_at', now());
  return out;
end $$;
revoke all on function public.pet_share_get(text) from public;
grant execute on function public.pet_share_get(text) to anon, authenticated;

select 'WangMiao migration v1.99 installed' as result;

-- ============================================================
-- 汪回家 WangHome — 資料庫升級 v1.3：支援貓
-- 可重複執行，不刪資料。
-- ============================================================

-- 1. 案件：species 只允許 dog / cat
alter table public.cases drop constraint if exists cases_species;
alter table public.cases add constraint cases_species check (species in ('dog','cat'));

-- 2. 拾獲通報加 species
alter table public.found_reports add column if not exists species text not null default 'dog';
alter table public.found_reports drop constraint if exists found_species;
alter table public.found_reports add constraint found_species check (species in ('dog','cat'));

-- 3. 建立案件 RPC：接受 species
create or replace function public.create_case(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_token text := encode(gen_random_bytes(18), 'hex');
  v_id uuid;
begin
  if coalesce(p->>'name','') = '' or coalesce(p->>'lost_city','') = '' or p->>'lost_at' is null then
    raise exception '缺少必填欄位';
  end if;
  insert into public.cases (
    species, name, breed, sex, size, colour, age_text, features, has_chip, chip_last4, neutered,
    collar_desc, temperament, lost_at, lost_city, lost_district, lost_place, lost_lat, lost_lng,
    photos, contact_name, contact_phone, phone_public, contact_email, contact_line, reward, notes, edit_token
  ) values (
    case when p->>'species' = 'cat' then 'cat' else 'dog' end,
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

-- 4. 建立拾獲通報 RPC：接受 species
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
    species, kind, seen_at, city, district, place_text, lat, lng, breed, sex, size, colour, features,
    collar_desc, current_place, photos, reporter_name, reporter_phone, phone_public, reporter_email,
    reporter_line, notes, edit_token
  ) values (
    case when p->>'species' = 'cat' then 'cat' else 'dog' end,
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

-- 5. 公開 view 加 species（重建，欄位順序改變需 drop）
drop view if exists public.found_public;
create view public.found_public with (security_invoker = false) as
select id, created_at, updated_at, species, kind, status, seen_at, city, district, place_text, lat, lng,
       breed, sex, size, colour, features, collar_desc, current_place, photos, reporter_name,
       case when phone_public then reporter_phone else null end as reporter_phone,
       phone_public, reporter_line, notes
from public.found_reports;
grant select on public.found_public to anon, authenticated;

create or replace view public.recent_sightings with (security_invoker = false) as
select s.id, s.case_id, s.seen_at, s.place_text, s.direction, s.photo_url,
       c.name as case_name, c.lost_city, c.lost_district, c.photos[1] as case_photo, c.species
from public.sightings s join public.cases c on c.id = s.case_id
where s.status = 'confirmed' and c.status = 'searching'
order by s.seen_at desc
limit 20;
grant select on public.recent_sightings to anon, authenticated;

grant all on public.found_reports to service_role;

select 'WangHome migration v1.3 installed' as result;

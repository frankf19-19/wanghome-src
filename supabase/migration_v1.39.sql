-- 汪喵回家 migration v1.39 — 農業部「寵物遺失啟事」匯入成協尋案件
--   可重複執行。由 GitHub Actions 排程（scripts/moa_sync.py）每 3 小時同步一次。
--   這些案件的飼主沒有在本站註冊：source = 'moa'，飼主電話照農業部公開的資料顯示；
--   Email 只存起來，「沒有驗證」所以排程不會寄任何通知信給他們。
alter table public.cases add column if not exists source text not null default 'site';
alter table public.cases add column if not exists source_id text;
create unique index if not exists cases_source_id_uq on public.cases(source_id) where source_id is not null;
create index if not exists cases_source_idx on public.cases(source);
revoke update (source, source_id) on public.cases from anon, authenticated;

-- 地區座標快取（縣市＋區的中心點，只用來在地圖上標大概位置）
create table if not exists public.geo_cache (
  name text primary key,
  lat double precision,
  lng double precision,
  updated_at timestamptz not null default now()
);
alter table public.geo_cache enable row level security;
revoke all on public.geo_cache from anon, authenticated;
grant all on public.geo_cache to service_role;

-- 新增案件的頻率限制：排程匯入時略過
create or replace function public.limit_cases() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('wh.import', true) = '1' then return new; end if;
  perform public.rate_check('case', 10, interval '1 hour', 300, interval '10 minutes');
  return new;
end $$;

-- 公開檢視加上 source
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
       c.source
from public.cases c
where not c.hidden;
grant select on public.cases_public to anon, authenticated;

-- 匯入／更新：p_rows 是整理好的案件；p_all_ids 是農業部目前所有申報的編號（不在裡面的＝飼主撤銷了，結案）
create or replace function public.moa_upsert(p_rows jsonb, p_all_ids text[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; n_new int := 0; n_upd int := 0; n_closed int := 0;
begin
  perform set_config('wh.import', '1', true);
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    update public.cases set
      name = r->>'name', species = r->>'species', breed = nullif(r->>'breed',''), sex = r->>'sex', colour = nullif(r->>'colour',''),
      features = nullif(r->>'features',''), lost_city = r->>'lost_city', lost_district = nullif(r->>'lost_district',''),
      lost_lat = coalesce((r->>'lost_lat')::float8, lost_lat), lost_lng = coalesce((r->>'lost_lng')::float8, lost_lng),
      photos = case when jsonb_typeof(r->'photos') = 'array' and jsonb_array_length(r->'photos') > 0
                    then array(select jsonb_array_elements_text(r->'photos')) else photos end,
      contact_phone = nullif(r->>'contact_phone',''), phone_public = true,
      updated_at = case when status <> 'searching' then now() else updated_at end,
      status = case when status = 'closed' and found_note like '飼主已撤銷%' then 'searching' else status end
    where source_id = r->>'source_id';
    if found then n_upd := n_upd + 1; continue; end if;
    insert into public.cases (source, source_id, status, name, species, breed, sex, colour, features, has_chip, chip_last4,
      lost_at, lost_city, lost_district, lost_lat, lost_lng, photos, contact_name, contact_phone, phone_public, contact_email,
      notes, edit_token, created_at, last_activity)
    values ('moa', r->>'source_id', 'searching', r->>'name', r->>'species', nullif(r->>'breed',''), r->>'sex', nullif(r->>'colour',''),
      nullif(r->>'features',''), nullif(r->>'chip_last4','') is not null, nullif(r->>'chip_last4',''),
      (r->>'lost_at')::timestamptz, r->>'lost_city', nullif(r->>'lost_district',''), (r->>'lost_lat')::float8, (r->>'lost_lng')::float8,
      coalesce(array(select jsonb_array_elements_text(coalesce(r->'photos','[]'::jsonb))), '{}'),
      '飼主', nullif(r->>'contact_phone',''), true, nullif(r->>'contact_email',''),
      '資料來源：農業部寵物登記管理資訊網「遺失啟事」', encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
      (r->>'lost_at')::timestamptz, (r->>'lost_at')::timestamptz);
    n_new := n_new + 1;
  end loop;
  -- 飼主在農業部撤銷了申報（找到了或不再協尋）：這邊也結案
  if p_all_ids is not null and array_length(p_all_ids, 1) > 50 then
    update public.cases set status = 'closed', found_at = now(), found_note = '飼主已撤銷農業部的遺失申報（可能已經找到）', updated_at = now()
    where source = 'moa' and status = 'searching' and source_id <> all(p_all_ids);
    get diagnostics n_closed = row_count;
  end if;
  return jsonb_build_object('new', n_new, 'updated', n_upd, 'closed', n_closed);
end $$;
revoke all on function public.moa_upsert(jsonb, text[]) from public, anon, authenticated;
grant execute on function public.moa_upsert(jsonb, text[]) to service_role;

select 'WangHome migration v1.39 installed' as result;

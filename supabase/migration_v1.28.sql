-- 汪喵回家 migration v1.28 — 案件公開頁顯示「有幾則目擊等待飼主確認」（只有數字，不公開內容）
-- 可重複執行。
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
       (select count(*) from public.sightings s where s.case_id = c.id and s.status = 'pending' and s.status_before_hide is null) as pending_count
from public.cases c
where not c.hidden;

grant select on public.cases_public to anon, authenticated;

select 'v1.28 ok' as result;

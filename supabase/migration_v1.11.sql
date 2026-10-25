-- 汪喵回家 migration v1.11 — 隱私與管理後台修正
--   1. 寵物檔案照片（photos/pets/…）不能再被列出清單；照片網址本身仍可正常顯示
--   2. 管理後台：被退回的目擊回報可以「恢復顯示」
--   3. 管理後台：可以查看已隱藏的案件內容（決定要不要恢復）
-- 可重複執行。

-- 1. 公開照片：讀取（列清單）時排除 pets 資料夾 --------------------------------
--    公開 bucket 的 /object/public/ 網址不經過這條規則，所以網頁上的 <img> 不受影響
drop policy if exists "public read photos" on storage.objects;
create policy "public read photos" on storage.objects for select to anon, authenticated
  using (bucket_id = 'photos' and coalesce((storage.foldername(name))[1], '') <> 'pets');

-- 2. 檢舉清單：目擊回報被退回時 target_hidden = true ----------------------------
create or replace function public.admin_reports(p_include_resolved boolean default false)
returns table(id uuid, created_at timestamptz, target_type text, target_id uuid, reason text, note text,
              resolved boolean, target_title text, target_hidden boolean, report_count bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return query
  select r.id, r.created_at, r.target_type, r.target_id, r.reason, r.note, r.resolved,
         coalesce(c.name, case when f.id is not null then coalesce(f.colour,'') || ' ' || f.city end,
                  case when s.id is not null then '目擊：' || coalesce(s.place_text,'') end) as target_title,
         coalesce(c.hidden, f.hidden, s.status = 'rejected', false) as target_hidden,
         (select count(*) from public.reports r2 where r2.target_id = r.target_id and not r2.resolved) as report_count
  from public.reports r
  left join public.cases c on r.target_type = 'case' and c.id = r.target_id
  left join public.found_reports f on r.target_type = 'found' and f.id = r.target_id
  left join public.sightings s on r.target_type = 'sighting' and s.id = r.target_id
  where p_include_resolved or not r.resolved
  order by r.resolved, r.created_at desc
  limit 300;
end $$;
grant execute on function public.admin_reports(boolean) to authenticated;

-- 3. 管理員查看案件（含已隱藏），欄位與 cases_public 相同 ------------------------
create or replace function public.admin_get_case(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare j jsonb;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  select to_jsonb(x) into j from (
    select id, created_at, updated_at, last_activity, status, name, species, breed, sex, size,
           colour, age_text, features, has_chip, chip_last4, neutered, collar_desc, temperament,
           lost_at, lost_city, lost_district, lost_place, lost_lat, lost_lng, photos,
           contact_name,
           case when phone_public then contact_phone else null end as contact_phone,
           phone_public, contact_line, reward, notes, found_at, found_note, found_method, view_count,
           (select count(*) from public.sightings s where s.case_id = c.id and s.status='confirmed') as sighting_count,
           (select max(seen_at) from public.sightings s where s.case_id = c.id and s.status='confirmed') as last_seen_at,
           hidden
    from public.cases c where c.id = p_id) x;
  return j;
end $$;
grant execute on function public.admin_get_case(uuid) to authenticated;

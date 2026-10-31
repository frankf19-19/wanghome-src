-- 汪喵回家 migration v1.40 — 農業部遺失申報：附近走失通知、目擊回報由站長轉告飼主
--   到 Supabase → SQL Editor 整段執行。可重複執行。
--   1. 附近走失通知（會員設定的「家附近」）也包含新的農業部遺失申報
--   2. 匯入時「建立時間」記成匯入當下（附近通知才會寄出新申報；排序仍照走失日期）
--   3. 農業部申報的飼主沒有使用本站：目擊回報由站長在後台看，打電話轉告飼主後標記

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
       and (c.email_verified or c.owner_id is not null or c.source = 'moa')   -- 確認過信箱、會員登記，或農業部遺失申報
       and c.created_at < now() - interval '30 minutes'           -- 剛登記就刪掉的灌水案件不會寄出
       and c.created_at > now() - make_interval(hours => p_hours)
       and (p.notify_species = 'all' or p.notify_species = c.species)
       and (c.owner_id is null or c.owner_id <> p.id)
  where p.notify_enabled and p.home_lat is not null and u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = p.id and l.kind = 'nearby' and l.ref_id = c.id)
    and 6371 * 2 * asin(sqrt(power(sin(radians(c.lost_lat - p.home_lat)/2),2) +
           cos(radians(p.home_lat)) * cos(radians(c.lost_lat)) * power(sin(radians(c.lost_lng - p.home_lng)/2),2))) <= p.home_radius_km;
$$;
revoke all on function public.nearby_targets(integer) from public, anon, authenticated;
grant execute on function public.nearby_targets(integer) to service_role;

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
      now(), (r->>'lost_at')::timestamptz);
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

-- 站長後台：農業部申報案件收到的目擊回報（含回報者聯絡方式與飼主電話，只有站長看得到）
create or replace function public.admin_moa_sightings(p_include_done boolean default false)
returns table(id uuid, case_id uuid, case_name text, species text, lost_city text, lost_district text, owner_phone text,
              seen_at timestamptz, created_at timestamptz, place_text text, direction text, note text, photo_url text,
              reporter_name text, reporter_contact text, status text, lat double precision, lng double precision)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return query
  select s.id, c.id, c.name, c.species, c.lost_city, c.lost_district, c.contact_phone,
         s.seen_at, s.created_at, s.place_text, s.direction, s.note, s.photo_url, s.reporter_name, s.reporter_contact, s.status, s.lat, s.lng
  from public.sightings s join public.cases c on c.id = s.case_id
  where c.source = 'moa' and (p_include_done or s.status = 'pending')
  order by s.created_at desc limit 200;
end $$;
revoke all on function public.admin_moa_sightings(boolean) from public, anon;
grant execute on function public.admin_moa_sightings(boolean) to authenticated;

-- 站長標記：confirmed＝已轉告飼主（公開到地圖）；rejected＝不像／無效（不公開）
create or replace function public.admin_sighting_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_status not in ('pending','confirmed','rejected') then raise exception '狀態錯誤'; end if;
  update public.sightings set status = p_status,
         confirmed_at = case when p_status = 'confirmed' and status <> 'confirmed' then now()
                             when p_status = 'confirmed' then confirmed_at else null end
   where id = p_id and status_before_hide is null;
  if not found then raise exception '找不到這筆回報'; end if;
end $$;
revoke all on function public.admin_sighting_status(uuid, text) from public, anon;
grant execute on function public.admin_sighting_status(uuid, text) to authenticated;

select 'WangHome migration v1.40 installed' as result;

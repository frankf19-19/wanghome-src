-- 汪喵回家 migration v1.77：路人通報 ↔ 走失毛孩，自動用照片比對並通知飼主
-- found_matches.photo_sim：null＝還沒比對照片；0～100＝照片相似度
alter table public.found_matches add column if not exists photo_sim integer;

-- 排程每小時呼叫：把照片比對結果同步到 shelter_matches、found_matches（首頁提醒、管理頁、Email 通知都讀這兩張表）
create or replace function public.sync_photo_matches() returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a int; b int; c int; d int;
begin
  -- 收容所：已有的配對更新相似度
  update public.shelter_matches m set photo_sim = x.sim, photo_checked_at = now()
  from (select m2.id, public.photo_score(max(1 - (cv.vec <=> sv.vec)))::int as sim
        from public.shelter_matches m2
        join public.cases cs on cs.id = m2.case_id and cs.status = 'searching'
        join public.photo_vecs cv on cv.kind = 'case' and cv.ref = m2.case_id::text and cv.ver = 2
        join public.photo_vecs sv on sv.kind = 'shelter' and sv.ref = m2.animal_id and sv.ver = 2
        where not m2.dismissed group by m2.id) x
  where m.id = x.id and m.photo_sim is distinct from x.sim;
  get diagnostics a = row_count;
  -- 收容所：每個協尋中的案件，照片最像的前 5 隻裡 75 分以上的補進來
  insert into public.shelter_matches (case_id, animal_id, animal_subid, shelter_name, shelter_tel, shelter_address, found_place, colour, bodytype, sex, variety, photo_url, score, photo_sim, photo_checked_at)
  select cs.id, r.ref, r.info->>'sub', r.info->>'shelter', r.info->>'tel', r.info->>'addr', r.info->>'place', r.info->>'colour', r.info->>'body', r.info->>'sex', r.info->>'variety', r.url, r.sim::int, r.sim::int, now()
  from public.cases cs cross join lateral public.case_photo_matches(cs.id, 5) r
  where cs.status = 'searching' and not cs.hidden and r.sim >= 75
  on conflict (case_id, animal_id) do nothing;
  get diagnostics b = row_count;
  -- 路人通報：已有的配對更新相似度
  update public.found_matches m set photo_sim = x.sim
  from (select m2.id, public.photo_score(max(1 - (cv.vec <=> fv.vec)))::int as sim
        from public.found_matches m2
        join public.cases cs on cs.id = m2.case_id and cs.status = 'searching'
        join public.photo_vecs cv on cv.kind = 'case' and cv.ref = m2.case_id::text and cv.ver = 2
        join public.photo_vecs fv on fv.kind = 'found' and fv.ref = m2.found_id::text and fv.ver = 2
        group by m2.id) x
  where m.id = x.id and m.photo_sim is distinct from x.sim;
  get diagnostics c = row_count;
  -- 路人通報：照片 80 分以上的補進來（不限縣市，走失的毛孩可能跑很遠）
  insert into public.found_matches (case_id, found_id, score, photo_sim)
  select cs.id, r.ref::uuid, r.sim::int, r.sim::int
  from public.cases cs cross join lateral public.case_photo_found(cs.id, 5) r
  where cs.status = 'searching' and not cs.hidden and r.sim >= 80
  on conflict (case_id, found_id) do nothing;
  get diagnostics d = row_count;
  return json_build_object('shelter_updated', a, 'shelter_added', b, 'found_updated', c, 'found_added', d);
end $$;
revoke all on function public.sync_photo_matches() from public, anon, authenticated;
grant execute on function public.sync_photo_matches() to service_role;
select 'WangMiao migration v1.77 installed' as result;

-- v1.97 照片比對變強：收容所比對多用一個大模型
-- photo_vecs.vec2：DINOv2-large（1024 維），先去背再算，只在主機排程算（scripts/photo_index2.py）
-- photo_score2：小模型和大模型的相似度各自標準化後相加，再換成 0～100 分（和原本的分數同一個刻度：
--   不同隻裡最像的那隻大約 62 分、同一隻大約 86 分）。大模型還沒算好的照片照舊只用小模型。
-- 實測（113 張考題、800 張照片）：第 1 名就找對 69% → 81%，前 5 名 86% → 94%
alter table public.photo_vecs add column if not exists vec2 extensions.vector(1024);
create index if not exists photo_vecs_vec2_todo on public.photo_vecs(kind) where vec2 is null;

create or replace function public.photo_score2(c1 double precision, c2 double precision) returns real language sql immutable as
$$ select case when c2 is null then public.photo_score(c1)
          else greatest(0, least(100, round((13.26 * ((c1 - 0.1842) / 0.1610 + (c2 - 0.1563) / 0.1518) - 15.3)::numeric)))::real end $$;

create or replace function public.case_photo_matches(p_case uuid, p_limit int default 8)
returns table (ref text, url text, info jsonb, sim real)
language plpgsql stable security definer set search_path = public, extensions as $$
declare c record; n int := greatest(1, least(coalesce(p_limit, 8), 20)); d0 text;
begin
  select id, species, sex, lost_city, lost_at, status, hidden into c from public.cases where id = p_case;
  if not found or c.status <> 'searching' or c.hidden then return; end if;
  d0 := to_char((c.lost_at at time zone 'Asia/Taipei')::date - 1, 'YYYY-MM-DD');
  return query
    with q as (select p.vec, p.vec2 from public.photo_vecs p where p.kind = 'case' and p.ref = p_case::text and p.ver = 2),
    cand as (
      select s.ref, s.url, s.info,
             max(public.photo_score2(1 - (s.vec <=> q.vec), case when s.vec2 is not null and q.vec2 is not null then 1 - (s.vec2 <=> q.vec2) end)) as sc,
             max(1 - (s.vec <=> q.vec)) as cos
      from public.photo_vecs s cross join q
      where s.kind = 'shelter' and s.ver = 2
        and coalesce(s.info->>'sp', 'dog') = coalesce(c.species, 'dog')
        and coalesce(s.info->>'at', '9999') >= d0
        and not (coalesce(c.sex,'') = 'male' and coalesce(s.info->>'sex','') = '母') and not (coalesce(c.sex,'') = 'female' and coalesce(s.info->>'sex','') = '公')
      group by s.ref, s.url, s.info
    ), best as (
      select distinct on (cand.ref) cand.ref, cand.url, cand.info, cand.sc, cand.cos from cand order by cand.ref, cand.sc desc, cand.cos desc
    )
    select b.ref, b.url, b.info, b.sc from best b order by b.sc desc, b.cos desc limit n;
end $$;

create or replace function public.sync_photo_matches() returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a int; b int; c int; d int;
begin
  -- 收容所：已有的配對更新相似度
  update public.shelter_matches m set photo_sim = x.sim, photo_checked_at = now()
  from (select m2.id, max(public.photo_score2(1 - (cv.vec <=> sv.vec), case when cv.vec2 is not null and sv.vec2 is not null then 1 - (cv.vec2 <=> sv.vec2) end))::int as sim
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
select 'WangMiao migration v1.97 installed' as result, (select count(*) from public.photo_vecs where kind in ('case','shelter') and ver = 2 and url not like '%#%') as photos;

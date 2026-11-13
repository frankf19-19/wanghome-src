-- 汪喵回家 migration v1.75：照片比對第 2 版——先用偵測模型把狗／貓框出來、裁掉背景，再算特徵
-- 實測（同一隻毛孩的多張照片當考題、混 800 張其他狗貓）：第 1 名就找對 34% → 58%，前 10 名內 82% → 93%
-- photo_vecs.ver：1＝舊算法（整張照片），2＝新算法；比對只用 ver=2，舊的由排程陸續重算
alter table public.photo_vecs add column if not exists ver smallint not null default 1;
create index if not exists photo_vecs_ver on public.photo_vecs(ver) where ver < 2;

-- 相似度分數：cos 0.35 → 0 分，0.80 → 100 分（實測同一隻的中位數 0.73 ≈ 85 分；不同隻裡最像的中位數 0.64 ≈ 65 分）
create or replace function public.photo_score(cos double precision) returns real language sql immutable as
$$ select greatest(0, least(100, round(((cos - 0.35) / 0.45 * 100)::numeric)))::real $$;

create or replace function public.photo_search(q text, p_sp text default null, p_city text default null, p_limit int default 20)
returns table (kind text, ref text, url text, info jsonb, sim real)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v vector(384) := q::vector(384); k text; n int := greatest(1, least(coalesce(p_limit, 20), 40));
begin
  foreach k in array array['case','found','shelter'] loop
    return query
      with top as (
        select p.kind, p.ref, p.url, p.info, (1 - (p.vec <=> v)) as cos
        from public.photo_vecs p
        where p.kind = k and p.ver = 2
          and (p_sp is null or p.info->>'sp' is null or p.info->>'sp' = p_sp)
          and (p_city is null or p.info->>'city' = p_city)
          and (k <> 'case'  or exists (select 1 from public.cases c where c.id::text = p.ref and c.status = 'searching' and not c.hidden))
          and (k <> 'found' or exists (select 1 from public.found_reports f where f.id::text = p.ref and f.status = 'open' and not coalesce(f.hidden, false)))
        order by p.vec <=> v
        limit n * 3
      ), best as (
        select distinct on (t.ref) t.kind, t.ref, t.url, t.info, t.cos from top t order by t.ref, t.cos desc
      )
      select b.kind, b.ref, b.url, b.info, public.photo_score(b.cos) from best b order by b.cos desc limit n;
  end loop;
end $$;

create or replace function public.case_photo_matches(p_case uuid, p_limit int default 8)
returns table (ref text, url text, info jsonb, sim real)
language plpgsql stable security definer set search_path = public, extensions as $$
declare c record; n int := greatest(1, least(coalesce(p_limit, 8), 20)); d0 text;
begin
  select id, species, lost_city, lost_at, status, hidden into c from public.cases where id = p_case;
  if not found or c.status <> 'searching' or c.hidden then return; end if;
  d0 := to_char((c.lost_at at time zone 'Asia/Taipei')::date - 1, 'YYYY-MM-DD');
  return query
    with q as (select p.vec from public.photo_vecs p where p.kind = 'case' and p.ref = p_case::text and p.ver = 2),
    cand as (
      select s.ref, s.url, s.info, max(1 - (s.vec <=> q.vec)) as cos
      from public.photo_vecs s cross join q
      where s.kind = 'shelter' and s.ver = 2
        and coalesce(s.info->>'sp', 'dog') = coalesce(c.species, 'dog')
        and s.info->>'city' = replace(c.lost_city, '台', '臺')
        and coalesce(s.info->>'at', '9999') >= d0
      group by s.ref, s.url, s.info
    ), best as (
      select distinct on (cand.ref) cand.ref, cand.url, cand.info, cand.cos from cand order by cand.ref, cand.cos desc
    )
    select b.ref, b.url, b.info, public.photo_score(b.cos) from best b order by b.cos desc limit n;
end $$;

create or replace function public.case_photo_ready(p_case uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.photo_vecs where kind = 'case' and ref = p_case::text and ver = 2) $$;

-- 排程在建好照片特徵之後呼叫：把照片比對的結果同步到 shelter_matches（首頁提醒、管理頁、Email 通知都讀這張表）
--   1. 表裡已有的配對：兩邊照片都算過的，更新 photo_sim
--   2. 每個協尋中的案件：照片最像的前 5 隻收容動物裡，相似 75 分以上的補進表裡
create or replace function public.sync_photo_matches() returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a int; b int;
begin
  update public.shelter_matches m set photo_sim = x.sim, photo_checked_at = now()
  from (select m2.id, public.photo_score(max(1 - (cv.vec <=> sv.vec)))::int as sim
        from public.shelter_matches m2
        join public.cases c on c.id = m2.case_id and c.status = 'searching'
        join public.photo_vecs cv on cv.kind = 'case' and cv.ref = m2.case_id::text and cv.ver = 2
        join public.photo_vecs sv on sv.kind = 'shelter' and sv.ref = m2.animal_id and sv.ver = 2
        where not m2.dismissed group by m2.id) x
  where m.id = x.id and m.photo_sim is distinct from x.sim;
  get diagnostics a = row_count;
  insert into public.shelter_matches (case_id, animal_id, animal_subid, shelter_name, shelter_tel, shelter_address, found_place, colour, bodytype, sex, variety, photo_url, score, photo_sim, photo_checked_at)
  select c.id, r.ref, r.info->>'sub', r.info->>'shelter', r.info->>'tel', r.info->>'addr', r.info->>'place', r.info->>'colour', r.info->>'body', r.info->>'sex', r.info->>'variety', r.url, r.sim::int, r.sim::int, now()
  from public.cases c cross join lateral public.case_photo_matches(c.id, 5) r
  where c.status = 'searching' and not c.hidden and r.sim >= 75
  on conflict (case_id, animal_id) do nothing;
  get diagnostics b = row_count;
  return json_build_object('updated', a, 'added', b);
end $$;
revoke all on function public.sync_photo_matches() from public, anon, authenticated;
grant execute on function public.sync_photo_matches() to service_role;
grant execute on function public.photo_score(double precision) to anon, authenticated, service_role;
select 'WangMiao migration v1.75 installed' as result;

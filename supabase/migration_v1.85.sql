-- v1.85 收容所照片比對：不限縣市，但性別不同的不列（兩邊都有填性別時）
create or replace function public.case_photo_matches(p_case uuid, p_limit int default 8)
returns table (ref text, url text, info jsonb, sim real)
language plpgsql stable security definer set search_path = public, extensions as $$
declare c record; n int := greatest(1, least(coalesce(p_limit, 8), 20)); d0 text;
begin
  select id, species, sex, lost_city, lost_at, status, hidden into c from public.cases where id = p_case;
  if not found or c.status <> 'searching' or c.hidden then return; end if;
  d0 := to_char((c.lost_at at time zone 'Asia/Taipei')::date - 1, 'YYYY-MM-DD');
  return query
    with q as (select p.vec from public.photo_vecs p where p.kind = 'case' and p.ref = p_case::text and p.ver = 2),
    cand as (
      select s.ref, s.url, s.info, max(1 - (s.vec <=> q.vec)) as cos
      from public.photo_vecs s cross join q
      where s.kind = 'shelter' and s.ver = 2
        and coalesce(s.info->>'sp', 'dog') = coalesce(c.species, 'dog')
        and coalesce(s.info->>'at', '9999') >= d0
        and not (c.sex = 'male' and s.info->>'sex' = '母') and not (c.sex = 'female' and s.info->>'sex' = '公')
      group by s.ref, s.url, s.info
    ), best as (
      select distinct on (cand.ref) cand.ref, cand.url, cand.info, cand.cos from cand order by cand.ref, cand.cos desc
    )
    select b.ref, b.url, b.info, public.photo_score(b.cos) from best b order by b.cos desc limit n;
end $$;
select 'WangMiao migration v1.85 installed' as result;

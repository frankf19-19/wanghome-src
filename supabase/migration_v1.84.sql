-- v1.84 收容所照片比對不限縣市：走失的毛孩可能跑很遠，也可能被帶到別的縣市，改成和全台收容所比
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
        and coalesce(s.info->>'at', '9999') >= d0
      group by s.ref, s.url, s.info
    ), best as (
      select distinct on (cand.ref) cand.ref, cand.url, cand.info, cand.cos from cand order by cand.ref, cand.cos desc
    )
    select b.ref, b.url, b.info, public.photo_score(b.cos) from best b order by b.cos desc limit n;
end $$;
select 'WangMiao migration v1.84 installed' as result;

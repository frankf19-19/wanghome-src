-- 汪喵回家 migration v1.74：收容所比對改成「看照片」
-- case_photo_matches：用走失毛孩已建好的照片向量（photo_vecs kind='case'），
-- 找同縣市、同種類、走失前一天之後才進收容所、照片最像的收容動物（不看毛色字面描述）
create or replace function public.case_photo_matches(p_case uuid, p_limit int default 8)
returns table (ref text, url text, info jsonb, sim real)
language plpgsql stable security definer set search_path = public, extensions as $$
declare c record; n int := greatest(1, least(coalesce(p_limit, 8), 20)); d0 text;
begin
  select id, species, lost_city, lost_at, status, hidden into c from public.cases where id = p_case;
  if not found or c.status <> 'searching' or c.hidden then return; end if;
  d0 := to_char((c.lost_at at time zone 'Asia/Taipei')::date - 1, 'YYYY-MM-DD');
  return query
    with q as (select p.vec from public.photo_vecs p where p.kind = 'case' and p.ref = p_case::text),
    cand as (
      select s.ref, s.url, s.info, max(1 - (s.vec <=> q.vec))::real as cos
      from public.photo_vecs s cross join q
      where s.kind = 'shelter'
        and coalesce(s.info->>'sp', 'dog') = coalesce(c.species, 'dog')
        and s.info->>'city' = replace(c.lost_city, '台', '臺')
        and coalesce(s.info->>'at', '9999') >= d0
      group by s.ref, s.url, s.info
    ), best as (
      select distinct on (cand.ref) cand.ref, cand.url, cand.info, cand.cos from cand order by cand.ref, cand.cos desc
    )
    select b.ref, b.url, b.info, greatest(0, least(100, round(((b.cos - 0.20) / 0.50 * 100)::numeric)))::real
    from best b order by b.cos desc limit n;
end $$;
revoke all on function public.case_photo_matches(uuid, int) from public;
grant execute on function public.case_photo_matches(uuid, int) to anon, authenticated, service_role;
-- 這個案件的照片向量建好了沒（網站用來顯示「照片還在建立中」）
create or replace function public.case_photo_ready(p_case uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.photo_vecs where kind = 'case' and ref = p_case::text) $$;
grant execute on function public.case_photo_ready(uuid) to anon, authenticated, service_role;
select 'WangMiao migration v1.74 installed' as result;

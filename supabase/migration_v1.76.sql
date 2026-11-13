-- 汪喵回家 migration v1.76：走失毛孩 ↔ 路人拍到／撿到的照片，用照片比對（不看文字條件）
-- case_photo_found：這隻走失毛孩的照片，和「走失前一天之後」的拾獲／目擊通報照片比，回傳最像的
create or replace function public.case_photo_found(p_case uuid, p_limit int default 6)
returns table (ref text, url text, info jsonb, sim real)
language plpgsql stable security definer set search_path = public, extensions as $$
declare c record; n int := greatest(1, least(coalesce(p_limit, 6), 20));
begin
  select id, species, lost_at, status, hidden into c from public.cases where id = p_case;
  if not found or c.status <> 'searching' or c.hidden then return; end if;
  return query
    with q as (select p.vec from public.photo_vecs p where p.kind = 'case' and p.ref = p_case::text and p.ver = 2),
    cand as (
      select s.ref, s.url, s.info, max(1 - (s.vec <=> q.vec)) as cos
      from public.photo_vecs s cross join q
      join public.found_reports f on f.id::text = s.ref and f.status = 'open' and not coalesce(f.hidden, false)
      where s.kind = 'found' and s.ver = 2
        and coalesce(s.info->>'sp', 'dog') = coalesce(c.species, 'dog')
        and f.seen_at >= c.lost_at - interval '1 day'
      group by s.ref, s.url, s.info
    ), best as (
      select distinct on (cand.ref) cand.ref, cand.url, cand.info, cand.cos from cand order by cand.ref, cand.cos desc
    )
    select b.ref, b.url, b.info, public.photo_score(b.cos) from best b order by b.cos desc limit n;
end $$;
revoke all on function public.case_photo_found(uuid, int) from public;
grant execute on function public.case_photo_found(uuid, int) to anon, authenticated, service_role;
select 'WangMiao migration v1.76 installed' as result;

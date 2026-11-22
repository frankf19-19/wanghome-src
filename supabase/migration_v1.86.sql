-- v1.86 更強的找回方式
-- 1. 附近即時推播：新登記的走失案件，推播給住在附近、有裝 App 的會員（每人最多 12 小時一則，晚上 10 點到早上 8 點不推）
-- 2. 拾獲／目擊照片反查走失案件：性別不同的不列
-- 3. 照片比對同步改由資料庫每小時自己跑（不再只靠 GitHub 排程）

create or replace function public.nearby_push_targets(p_hours integer default 8)
returns table(user_id uuid, case_id uuid, case_name text, species text, lost_city text, lost_district text, distance_km double precision)
language sql stable security definer set search_path = public as $$
  select p.id, c.id, c.name, c.species, c.lost_city, c.lost_district,
         6371 * 2 * asin(sqrt(power(sin(radians(c.lost_lat - p.home_lat)/2),2) +
           cos(radians(p.home_lat)) * cos(radians(c.lost_lat)) * power(sin(radians(c.lost_lng - p.home_lng)/2),2))) as d
  from public.profiles p
  join public.cases c on c.status = 'searching' and c.lost_lat is not null and not c.hidden
       and c.created_at < now() - interval '20 minutes'
       and c.created_at > now() - make_interval(hours => p_hours)
       and c.lost_at > now() - interval '14 days'
       and (p.notify_species = 'all' or p.notify_species = c.species)
       and (c.owner_id is null or c.owner_id <> p.id)
  where p.notify_enabled and p.home_lat is not null
    and exists (select 1 from public.push_tokens t where t.user_id = p.id)
    and not exists (select 1 from public.notify_log l where l.user_id = p.id and l.kind = 'nearby_push' and l.ref_id = c.id)
    and not exists (select 1 from public.notify_log l where l.user_id = p.id and l.kind = 'nearby_push' and l.sent_at > now() - interval '12 hours')
    and 6371 * 2 * asin(sqrt(power(sin(radians(c.lost_lat - p.home_lat)/2),2) +
           cos(radians(p.home_lat)) * cos(radians(c.lost_lat)) * power(sin(radians(c.lost_lng - p.home_lng)/2),2))) <= least(p.home_radius_km, 10);
$$;
revoke all on function public.nearby_push_targets(integer) from public, anon, authenticated;
grant execute on function public.nearby_push_targets(integer) to service_role;

create or replace function public.case_photo_found(p_case uuid, p_limit int default 6)
returns table (ref text, url text, info jsonb, sim real)
language plpgsql stable security definer set search_path = public, extensions as $$
declare c record; n int := greatest(1, least(coalesce(p_limit, 6), 20));
begin
  select id, species, sex, lost_at, status, hidden into c from public.cases where id = p_case;
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
        and not (coalesce(c.sex,'') in ('male','female') and coalesce(f.sex,'') in ('male','female') and f.sex <> c.sex)
      group by s.ref, s.url, s.info
    ), best as (
      select distinct on (cand.ref) cand.ref, cand.url, cand.info, cand.cos from cand order by cand.ref, cand.cos desc
    )
    select b.ref, b.url, b.info, public.photo_score(b.cos) from best b order by b.cos desc limit n;
end $$;

do $$ begin perform cron.unschedule('wanghome-photo-sync'); exception when others then null; end $$;
select cron.schedule('wanghome-photo-sync', '41 * * * *', $$select public.sync_photo_matches()$$);
select 'WangMiao migration v1.86 installed' as result;

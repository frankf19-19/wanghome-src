-- 汪喵回家 migration v1.96 — 民眾送養：主動推播提醒（每 2 小時由 daily-run 的 notify 跑一次，晚上 10 點到早上 8 點不推）
--   1. 約好的見面：前一天提醒雙方
--   2. 接回家後該回報近況了：提醒領養人（隔天、一週、一個月、之後每三個月）
--   3. 刊登 45 天沒更新：問送養人還在找家嗎
--   每一則只推一次（記在 notify_log）。可重複執行。
create or replace function public.rehome_push_targets()
returns table(user_id uuid, kind text, ref_id uuid, title text, body text, url text)
language sql stable security definer set search_path = public as $$
  with t as (
    -- 見面提醒（雙方）
    select x.uid, 'rh_meet_' || to_char(a.meet_at at time zone 'Asia/Taipei', 'MMDDHH24MI') as kind, a.id as ref,
           '明天要見面了' as title,
           to_char(a.meet_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || ' 要跟' || x.other || '見面' ||
             coalesce('：' || a.meet_place, '') || '（' || r.name || '）。記得約在公開場所、當面核對證件。' as body,
           '#/rehome/app/' || a.id as url
      from public.rehome_apps a join public.rehomes r on r.id = a.rehome_id
      cross join lateral (values (r.owner_id, a.contact_name), (a.applicant_id, r.contact_name)) as x(uid, other)
     where a.status = 'meet' and a.meet_at between now() + interval '1 hour' and now() + interval '26 hours'
    union all
    -- 近況回報提醒（領養人）
    select a.applicant_id, 'rh_fu' || f.p, a.id,
           r.name || '最近好嗎？',
           '接回家第 ' || f.p || ' 天了，傳一張' || r.name || '的近況照片給送養人吧。',
           '#/rehome/app/' || a.id
      from public.rehome_apps a join public.rehomes r on r.id = a.rehome_id
      cross join lateral (select max(d) as p from unnest(array[1,7,30,90,180,270,365]) d where now() >= r.adopted_at + make_interval(days => d)) f
     where a.status = 'adopted' and r.req_followup and r.adopted_at is not null and f.p is not null
       and now() < r.adopted_at + make_interval(days => f.p + 3)
       and not exists (select 1 from public.rehome_updates u where u.app_id = a.id and u.created_at >= r.adopted_at + make_interval(days => f.p) - interval '12 hours')
    union all
    -- 刊登久沒更新（送養人）
    select r.owner_id, 'rh_stale_' || to_char(r.updated_at, 'YYYYMMDD'), r.id,
           r.name || '還在找家嗎？',
           '刊登超過 45 天沒有更新了。還在找的話點一下「還在找」，刊登才會留在列表上；已經送出的話，記得改狀態。',
           '#/rehome/' || r.id || '/apps'
      from public.rehomes r
     where r.status = 'open' and not r.hidden and r.updated_at < now() - interval '45 days' and r.updated_at > now() - interval '120 days'
  )
  select t.uid, t.kind, t.ref, t.title, t.body, t.url from t
   where not exists (select 1 from public.notify_log n where n.user_id = t.uid and n.kind = t.kind and n.ref_id = t.ref)
   limit 300;
$$;
revoke all on function public.rehome_push_targets() from public, anon, authenticated;
grant execute on function public.rehome_push_targets() to service_role;

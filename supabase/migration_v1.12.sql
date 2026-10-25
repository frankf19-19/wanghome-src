-- 汪喵回家 migration v1.12 — 通知修正
--   1. 追蹤通知排除被站長隱藏的案件
--   2. 健康提醒：改了「下次到期日」之後會再提醒一次（以「紀錄＋到期日」判斷是否寄過）
-- 可重複執行。

create or replace function public.follow_targets(p_hours integer default 26)
returns table(user_id uuid, email text, case_id uuid, case_name text, sighting_id uuid, seen_at timestamptz, place_text text)
language sql stable security definer set search_path = public, auth as $$
  select f.user_id, u.email::text, c.id, c.name, s.id, s.seen_at, s.place_text
  from public.follows f
  join public.profiles p on p.id = f.user_id and p.notify_follow
  join auth.users u on u.id = f.user_id
  join public.cases c on c.id = f.case_id and c.status = 'searching' and not c.hidden
  join public.sightings s on s.case_id = c.id and s.status = 'confirmed' and s.created_at > now() - make_interval(hours => p_hours)
  where u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = f.user_id and l.kind = 'follow' and l.ref_id = s.id);
$$;
revoke all on function public.follow_targets(integer) from public, anon, authenticated;
grant execute on function public.follow_targets(integer) to service_role;

-- notify_log.kind 存成 'due:2026-11-24'，同一筆紀錄換了到期日就是新的提醒
create or replace function public.due_targets()
returns table(user_id uuid, email text, record_id uuid, pet_name text, title text, next_due date)
language sql stable security definer set search_path = public, auth as $$
  select r.owner_id, u.email::text, r.id, p.name, r.title, r.next_due
  from public.pet_records r
  join public.pets p on p.id = r.pet_id
  join auth.users u on u.id = r.owner_id
  where r.next_due is not null and not r.done
    and r.next_due <= (now() at time zone 'Asia/Taipei')::date + 7
    and r.next_due >= (now() at time zone 'Asia/Taipei')::date - 30
    and u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = r.owner_id
                    and l.kind = 'due:' || r.next_due::text and l.ref_id = r.id);
$$;
revoke all on function public.due_targets() from public, anon, authenticated;
grant execute on function public.due_targets() to service_role;

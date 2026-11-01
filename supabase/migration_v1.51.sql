-- 汪喵回家 migration v1.51 — 管理後台小修正（可重複執行）
--   1. 檢舉列表：退回的目擊顯示「已隱藏」，可以恢復
--   2. 檢舉私訊會員時附上的訊息改成最新的在前面（超過 500 字時保留最新的）

create or replace function public.admin_reports(p_include_resolved boolean default false)
returns table(id uuid, created_at timestamptz, target_type text, target_id uuid, reason text, note text,
              resolved boolean, target_title text, target_hidden boolean, report_count bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return query
  select r.id, r.created_at, r.target_type, r.target_id, r.reason, r.note, r.resolved,
         coalesce(c.name, case when f.id is not null then coalesce(f.colour,'') || ' ' || f.city end,
                  case when s.id is not null then '目擊：' || coalesce(s.place_text,'') end,
                  case when pu.id is not null then '會員：' || coalesce(pu.username, '（未設定名稱）') end) as target_title,
         coalesce(c.hidden, f.hidden, s.status = 'rejected', false) as target_hidden,
         (select count(*) from public.reports r2 where r2.target_id = r.target_id and not r2.resolved) as report_count
  from public.reports r
  left join public.cases c on r.target_type = 'case' and c.id = r.target_id
  left join public.found_reports f on r.target_type = 'found' and f.id = r.target_id
  left join public.sightings s on r.target_type = 'sighting' and s.id = r.target_id
  left join public.profiles pu on r.target_type = 'user' and pu.id = r.target_id
  where p_include_resolved or not r.resolved
  order by r.resolved, r.created_at desc
  limit 300;
end $$;
revoke execute on function public.admin_reports(boolean) from anon, public;
grant execute on function public.admin_reports(boolean) to authenticated;


create or replace function public.chat_report(p_chat uuid, p_reason text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare other uuid; snap text;
begin
  if auth.uid() is null or not public.is_chat_member(p_chat) then raise exception '找不到這個對話'; end if;
  select user_id into other from public.chat_members where chat_id = p_chat and user_id <> auth.uid() limit 1;
  if other is null then return; end if;
  if exists (select 1 from public.reports where target_type = 'user' and target_id = other and reporter_id = auth.uid() and not resolved) then return; end if;
  select string_agg(to_char(created_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || ' ' || coalesce(body, '［照片］'), E'\n' order by id desc)
    into snap from (select * from public.chat_messages where chat_id = p_chat and sender_id = other order by id desc limit 10) t;
  insert into public.reports (target_type, target_id, reason, note, reporter_id)
  values ('user', other, left(coalesce(p_reason, 'other'), 50), left(coalesce(p_note, '') || E'\n［私訊 ' || p_chat::text || E'］\n' || coalesce(snap, ''), 500), auth.uid());
end $$;

select 'WangHome migration v1.51 installed' as result;

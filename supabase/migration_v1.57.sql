-- 汪喵回家 migration v1.57 — 會員頁可以直接檢舉會員（可重複執行）
create or replace function public.user_report(p_user uuid, p_reason text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare snap text;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if p_user is null or p_user = auth.uid() or not exists (select 1 from public.profiles where id = p_user) then raise exception '找不到這位會員'; end if;
  if exists (select 1 from public.reports where target_type = 'user' and target_id = p_user and reporter_id = auth.uid() and not resolved) then return; end if;
  perform public.rate_check('report', 20, interval '10 minutes', 500, interval '10 minutes');
  -- 附上對方最近傳給檢舉人的訊息，方便站長判斷
  select string_agg(to_char(m.created_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || ' ' || coalesce(m.body, '［照片］'), E'\n' order by m.id desc)
    into snap from (select cm.* from public.chat_messages cm
      where cm.sender_id = p_user and exists (select 1 from public.chat_members me where me.chat_id = cm.chat_id and me.user_id = auth.uid())
      order by cm.id desc limit 10) m;
  insert into public.reports (target_type, target_id, reason, note, reporter_id)
  values ('user', p_user, left(coalesce(p_reason, 'other'), 50), left(coalesce(p_note, '') || E'\n［會員頁檢舉］\n' || coalesce(snap, ''), 500), auth.uid());
end $$;
revoke execute on function public.user_report(uuid, text, text) from public, anon;
grant execute on function public.user_report(uuid, text, text) to authenticated;
select 'WangHome migration v1.57 installed' as result;

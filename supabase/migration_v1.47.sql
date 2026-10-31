-- 汪喵回家 migration v1.47 — 登入過期（不是自己按登出）時，也能把這支手機的推播停掉（可重複執行）
-- 推播代碼只有那支手機自己知道，所以拿得出代碼就可以把它從名單移除（不需要登入）
create or replace function public.drop_push_token(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_tokens where token = p_token and coalesce(p_token,'') ~ '^[A-Za-z0-9:_\-]{20,300}$';
$$;
revoke all on function public.drop_push_token(text) from public;
grant execute on function public.drop_push_token(text) to anon, authenticated;

select 'WangHome migration v1.47 installed' as result;

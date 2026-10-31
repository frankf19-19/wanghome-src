-- 汪喵回家 migration v1.48 — 修正推播代碼檢查（資料庫不接受超過 255 次的重複規則，改用長度判斷）（可重複執行）
create or replace function public.save_push_token(p_token text, p_platform text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if (coalesce(p_token,'') !~ '^[A-Za-z0-9:_\-]+$' or length(p_token) not between 20 and 300) or p_platform not in ('ios','android') then raise exception 'bad token'; end if;
  insert into public.push_tokens(token, user_id, platform, updated_at) values (p_token, auth.uid(), p_platform, now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
  -- 一個帳號最多記 10 支手機
  delete from public.push_tokens where user_id = auth.uid() and token not in
    (select token from public.push_tokens where user_id = auth.uid() order by updated_at desc limit 10);
end $$;
create or replace function public.drop_push_token(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_tokens where token = p_token and coalesce(p_token,'') ~ '^[A-Za-z0-9:_\-]+$' and length(p_token) between 20 and 300;
$$;
revoke all on function public.save_push_token(text,text), public.drop_push_token(text) from public;
revoke all on function public.save_push_token(text,text) from anon;
grant execute on function public.save_push_token(text,text) to authenticated;
grant execute on function public.drop_push_token(text) to anon, authenticated;

select 'WangHome migration v1.48 installed' as result;

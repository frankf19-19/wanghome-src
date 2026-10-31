-- 汪喵回家 migration v1.46 — 手機推播通知：記錄每支手機的推播代碼（可重複執行）
create table if not exists public.push_tokens (
  token       text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  platform    text not null check (platform in ('ios','android')),
  updated_at  timestamptz not null default now()
);
create index if not exists push_tokens_user_idx on public.push_tokens(user_id);
alter table public.push_tokens enable row level security;
revoke all on public.push_tokens from anon, authenticated;
grant all on public.push_tokens to service_role;

-- App 登入後呼叫：把這支手機的推播代碼記到目前帳號（換帳號登入會自動換人）
create or replace function public.save_push_token(p_token text, p_platform text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if coalesce(p_token,'') !~ '^[A-Za-z0-9:_\-]{20,300}$' or p_platform not in ('ios','android') then raise exception 'bad token'; end if;
  insert into public.push_tokens(token, user_id, platform, updated_at) values (p_token, auth.uid(), p_platform, now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
  -- 一個帳號最多記 10 支手機
  delete from public.push_tokens where user_id = auth.uid() and token not in
    (select token from public.push_tokens where user_id = auth.uid() order by updated_at desc limit 10);
end $$;
-- 登出時呼叫：這支手機不要再收到這個帳號的推播
create or replace function public.drop_push_token(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_tokens where token = p_token and user_id = auth.uid();
$$;
revoke all on function public.save_push_token(text,text), public.drop_push_token(text) from public, anon;
grant execute on function public.save_push_token(text,text), public.drop_push_token(text) to authenticated;

select 'WangHome migration v1.46 installed' as result;

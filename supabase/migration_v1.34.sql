-- 汪喵回家 migration v1.34 — 使用者名稱（註冊時設定，之後不能改）
--   到 Supabase → SQL Editor 整段執行。可重複執行。
--
--   1. profiles.username：2–20 字，中文、英文、數字、底線；不分大小寫不能重複
--   2. 一旦設定就不能修改（只有站方用 service_role 才能改）
--   3. 用 Email＋密碼註冊時，把註冊表單填的名稱直接存進去（raw_user_meta_data.username）
--   4. username_available(name)：註冊前檢查名稱能不能用（未登入也能查）
--   5. set_username(name)：用 LINE／Google／Apple／驗證碼登入、還沒有名稱的人，設定一次

alter table public.profiles add column if not exists username text;

do $$ begin
  alter table public.profiles add constraint profiles_username_fmt
    check (username is null or (char_length(username) between 2 and 20 and username ~ '^[A-Za-z0-9_一-鿿㐀-䶿]+$'));
exception when duplicate_object then null; end $$;

create unique index if not exists profiles_username_uq on public.profiles (lower(username)) where username is not null;

-- 名稱設定後不能改
create or replace function public.profiles_username_lock() returns trigger
language plpgsql as $$
begin
  if old.username is not null and new.username is distinct from old.username
     and coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres', 'supabase_admin') then
    raise exception '使用者名稱設定後不能修改' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists profiles_username_lock on public.profiles;
create trigger profiles_username_lock before update of username on public.profiles
  for each row execute function public.profiles_username_lock();

-- 註冊時帶入名稱（名稱不合格或被用走就先留空，登入後再請他設定）
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  u text := nullif(trim(coalesce(new.raw_user_meta_data->>'username', '')), '');
begin
  if u is not null and (char_length(u) not between 2 and 20
       or u !~ '^[A-Za-z0-9_一-鿿㐀-䶿]+$'
       or exists (select 1 from public.profiles where lower(username) = lower(u))) then
    u := null;
  end if;
  insert into public.profiles (id, display_name, username)
  values (new.id, coalesce(u, split_part(coalesce(new.email, ''), '@', 1)), u)
  on conflict (id) do nothing;
  return new;
end $$;

create or replace function public.username_available(name text) returns boolean
language sql stable security definer set search_path = public as $$
  select char_length(trim(name)) between 2 and 20
     and trim(name) ~ '^[A-Za-z0-9_一-鿿㐀-䶿]+$'
     and not exists (select 1 from public.profiles where lower(username) = lower(trim(name)));
$$;
revoke all on function public.username_available(text) from public;
grant execute on function public.username_available(text) to anon, authenticated;

create or replace function public.set_username(name text) returns text
language plpgsql security definer set search_path = public as $$
declare
  n text := trim(name);
  cur text;
begin
  if auth.uid() is null then raise exception '請先登入' using errcode = 'P0001'; end if;
  select username into cur from public.profiles where id = auth.uid();
  if cur is not null then raise exception '使用者名稱設定後不能修改' using errcode = 'P0001'; end if;
  if not public.username_available(n) then raise exception '這個名稱不能用或已經有人用了' using errcode = 'P0001'; end if;
  insert into public.profiles (id, display_name, username) values (auth.uid(), n, n)
  on conflict (id) do update set username = excluded.username, display_name = excluded.username;
  return n;
end $$;
revoke all on function public.set_username(text) from public;
grant execute on function public.set_username(text) to authenticated;

select 'WangHome migration v1.34 installed' as result;

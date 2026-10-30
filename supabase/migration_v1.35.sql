-- 汪喵回家 migration v1.35 — 使用者名稱：驗證完 Email 才保留名稱；同時搶同一個名稱時不會讓註冊失敗
--   到 Supabase → SQL Editor 整段執行。可重複執行。
--
--   1. 用 Email＋密碼註冊：名稱先記在註冊資料裡，等 Email 驗證完成才寫進 profiles.username
--      （避免有人用假 Email 大量註冊、先把好名字佔走）
--   2. 驗證完成時名稱剛好被別人用走：先留空，登入後 App 會請他重新設定
--   3. 兩個人同時搶同一個名稱：不會讓註冊或設定失敗變成看不懂的錯誤

create or replace function public.wh_valid_username(u text) returns boolean
language sql immutable as $$
  select u is not null and char_length(u) between 2 and 20 and u ~ '^[A-Za-z0-9_一-鿿㐀-䶿]+$';
$$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  u text := nullif(trim(coalesce(new.raw_user_meta_data->>'username', '')), '');
begin
  if not public.wh_valid_username(u) then u := null; end if;
  -- 還沒驗證 Email：先不保留名稱
  if new.email_confirmed_at is null then
    insert into public.profiles (id, display_name)
    values (new.id, coalesce(u, split_part(coalesce(new.email, ''), '@', 1)))
    on conflict (id) do nothing;
    return new;
  end if;
  begin
    insert into public.profiles (id, display_name, username)
    values (new.id, coalesce(u, split_part(coalesce(new.email, ''), '@', 1)), u)
    on conflict (id) do nothing;
  exception when unique_violation then
    insert into public.profiles (id, display_name)
    values (new.id, coalesce(u, split_part(coalesce(new.email, ''), '@', 1)))
    on conflict (id) do nothing;
  end;
  return new;
end $$;

-- Email 驗證完成的那一刻：把註冊時填的名稱寫進去（名稱還沒被用走才寫）
create or replace function public.handle_user_confirmed() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  u text := nullif(trim(coalesce(new.raw_user_meta_data->>'username', '')), '');
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null and public.wh_valid_username(u) then
    begin
      update public.profiles set username = u, display_name = u
       where id = new.id and username is null
         and not exists (select 1 from public.profiles p2 where lower(p2.username) = lower(u) and p2.id <> new.id);
    exception when unique_violation then null;
    end;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed after update of email_confirmed_at on auth.users
  for each row execute function public.handle_user_confirmed();

-- set_username：同時搶同一個名稱時回傳看得懂的訊息
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
  begin
    insert into public.profiles (id, display_name, username) values (auth.uid(), n, n)
    on conflict (id) do update set username = excluded.username, display_name = excluded.username;
  exception when unique_violation then
    raise exception '這個名稱已經有人用了' using errcode = 'P0001';
  end;
  return n;
end $$;
revoke all on function public.set_username(text) from public;
grant execute on function public.set_username(text) to authenticated;

select 'WangHome migration v1.35 installed' as result;

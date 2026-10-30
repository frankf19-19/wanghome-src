-- 汪喵回家 migration v1.38 — 暱稱（3 個月可以改一次）＋大頭貼
--   到 Supabase → SQL Editor 整段執行。可重複執行。
--   使用者名稱（username）還是註冊後不能改；暱稱（display_name）是顯示用的名字，3 個月可以改一次。
--   大頭貼放在公開照片空間 photos/pets/<會員>/avatar-…jpg（只接受自己資料夾裡的照片）。
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists display_name_changed_at timestamptz;

create or replace function public.profiles_nick_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_next timestamptz;
begin
  -- 大頭貼：只能是自己資料夾裡的照片
  if new.avatar_url is distinct from old.avatar_url and new.avatar_url is not null then
    if new.avatar_url !~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/photos/pets/' || new.id::text || '/avatar-[A-Za-z0-9_-]+\.jpg$') then
      raise exception '大頭貼網址不正確' using errcode = 'P0001';
    end if;
  end if;
  -- 暱稱：只有本人自己改的時候才算次數（註冊、設定使用者名稱時系統帶入的不算）
  if new.display_name is distinct from old.display_name
     and auth.uid() is not null and auth.uid() = new.id
     and new.username is not distinct from old.username then
    new.display_name := nullif(btrim(new.display_name), '');
    if new.display_name is null or char_length(new.display_name) > 20 then
      raise exception '暱稱要 1～20 個字' using errcode = 'P0001';
    end if;
    if public.ugc_bad(new.display_name) then
      raise exception '暱稱裡有不適當的字，請換一個' using errcode = 'P0001';
    end if;
    if old.display_name_changed_at is not null then
      v_next := old.display_name_changed_at + interval '90 days';
      if now() < v_next then
        raise exception '暱稱 3 個月只能改一次，% 之後可以再改', to_char(v_next at time zone 'Asia/Taipei', 'YYYY/MM/DD') using errcode = 'P0001';
      end if;
    end if;
    new.display_name_changed_at := now();
  end if;
  -- 不能自己改「上次改暱稱的時間」
  if auth.uid() is not null and new.display_name is not distinct from old.display_name then
    new.display_name_changed_at := old.display_name_changed_at;
  end if;
  return new;
end $$;
drop trigger if exists profiles_nick_guard on public.profiles;
create trigger profiles_nick_guard before update on public.profiles
  for each row execute function public.profiles_nick_guard();

select 'WangHome migration v1.38 installed' as result;

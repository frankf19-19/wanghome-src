-- ============================================================
-- 汪喵回家 — 資料庫升級 v1.7：日曆訂閱
--   profiles.calendar_token：私人日曆訂閱網址用的金鑰（可重設）
-- 可重複執行，不刪資料。
-- ============================================================
alter table public.profiles add column if not exists calendar_token uuid not null default gen_random_uuid();
create unique index if not exists profiles_calendar_token_idx on public.profiles(calendar_token);

-- 重設訂閱網址（舊網址立刻失效）
create or replace function public.rotate_calendar_token()
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid := gen_random_uuid();
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  update public.profiles set calendar_token = v where id = auth.uid();
  return v;
end $$;
grant execute on function public.rotate_calendar_token() to authenticated;

select 'WangMiao migration v1.7 installed' as result;

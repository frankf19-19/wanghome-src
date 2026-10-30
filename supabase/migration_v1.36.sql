-- 汪喵回家 migration v1.36 — 電子毛孩 AI 畫圖的次數紀錄（控制費用用）
--   到 Supabase → SQL Editor 整段執行。可重複執行。
create table if not exists public.buddy_art_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  pose text,
  model text,
  created_at timestamptz not null default now()
);
create index if not exists buddy_art_log_user_at on public.buddy_art_log(user_id, created_at desc);
create index if not exists buddy_art_log_at on public.buddy_art_log(created_at desc);
alter table public.buddy_art_log enable row level security;
revoke all on public.buddy_art_log from anon, authenticated;

select 'WangHome migration v1.36 installed' as result;

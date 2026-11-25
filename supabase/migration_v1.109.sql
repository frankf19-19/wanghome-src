-- 汪喵回家 migration v1.109 — 網友協尋自動發文加 Reel；粉專/IG/Threads 貼文底下網友留的線索，自動轉成目擊回報通知飼主
--   搭配 Edge Function social-post 的 mode=comments（每 20 分鐘）。可重複執行。
-- 自動 Reel：GitHub Actions（auto-reel.yml）做好 Reel 和海報後寫回這兩欄
alter table public.cases add column if not exists social_reel_url text;
alter table public.cases add column if not exists social_poster_url text;

-- 有 Reel 之後每次只發 1 則（IG Reel 要處理時間），所以改成每 10 分鐘跑一次
do $$ begin perform cron.unschedule('wanghome-social'); exception when others then null; end $$;
select cron.schedule('wanghome-social', '*/10 * * * *', $$select public.social_post_call('cases')$$);

create table if not exists public.social_comments_seen (
  id         text primary key,              -- 平台:留言 id
  case_id    uuid references public.cases(id) on delete cascade,
  platform   text not null,
  forwarded  boolean not null default false, -- 有沒有轉成目擊回報
  created_at timestamptz not null default now()
);
alter table public.social_comments_seen enable row level security;
revoke all on public.social_comments_seen from anon, authenticated;

do $$ begin
  perform cron.unschedule('wanghome-social-comments');
exception when others then null; end $$;
select cron.schedule('wanghome-social-comments', '*/20 * * * *', $$select public.social_post_call('comments')$$);

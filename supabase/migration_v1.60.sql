-- 汪喵回家 migration v1.60 — 新協尋案件自動分享到 FB 粉專／IG，以及每週「本週找回」貼文
--   搭配 Edge Function「social-post」（關閉 Verify JWT，用 daily_run_secret 驗證）。
--   可重複執行。

-- 1) 案件：飼主是否同意粉專分享、分享紀錄
alter table public.cases add column if not exists social_ok boolean not null default true;
alter table public.cases add column if not exists social_posted_at timestamptz;
alter table public.cases add column if not exists social_post jsonb;

-- 這個功能上線前就登記的案件不補發（避免一次洗版）
update public.cases set social_posted_at = now()
 where social_posted_at is null and created_at < now();

-- 2) 飼主用管理密碼關掉／打開粉專分享
create or replace function public.set_social_ok(p_case uuid, p_token text, p_ok boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.cases set social_ok = coalesce(p_ok, true)
   where id = p_case and edit_token = p_token;
  get diagnostics n = row_count;
  return n > 0;
end $$;
revoke all on function public.set_social_ok(uuid, text, boolean) from public;
grant execute on function public.set_social_ok(uuid, text, boolean) to anon, authenticated;

-- 3) 呼叫 social-post 的小工具（共用 daily_run_secret）
create or replace function public.social_post_call(p_mode text) returns bigint
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://nopyhfpaykkiieudvoko.supabase.co/functions/v1/social-post',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-run-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'daily_run_secret')),
    body := jsonb_build_object('mode', p_mode),
    timeout_milliseconds := 10000);
$$;
revoke all on function public.social_post_call(text) from public, anon, authenticated;

-- 4) 排程（UTC）：每 30 分鐘發新案件；每週日 20:07 台灣時間發「本週找回」
select cron.schedule('wanghome-social',        '*/30 * * * *', $$select public.social_post_call('cases')$$);
select cron.schedule('wanghome-social-weekly', '7 12 * * 0',   $$select public.social_post_call('weekly')$$);

-- 手動測試：select public.social_post_call('probe');
-- 停掉：select cron.unschedule('wanghome-social'); select cron.unschedule('wanghome-social-weekly');

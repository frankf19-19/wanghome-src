-- 汪喵回家 migration v1.33 — 每日比對／通知改由 Supabase 自己排程（不再用 GitHub Actions）
--   先部署 Edge Function「daily-run」（關閉 Verify JWT），再到 SQL Editor 整段執行本檔。
--   可重複執行（排程同名會覆蓋、密碼已存在就沿用）。
--
--   排程時間（伺服器用 UTC）：
--     每天 03:17 台灣  nightly ：比對＋所有通知＋到期提醒＋定期清理
--     每天 03:47 台灣  cleanup ：清掉沒人用的公開照片
--     每 2 小時 :21    notify  ：拾獲比對＋目擊／比對通知（若剛好遇到別的還在跑，會自己略過這次）

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1) 排程呼叫函式用的密碼：隨機產生，只存在 Vault，不用複製到任何地方
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'daily_run_secret') then
    perform vault.create_secret(
      replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
      'daily_run_secret',
      'daily-run Edge Function 排程密碼');
  end if;
end $$;

-- 2) 讓 Edge Function 檢查密碼對不對（只有 service_role 能呼叫）
create or replace function public.daily_run_secret_ok(p text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from vault.decrypted_secrets
    where name = 'daily_run_secret' and decrypted_secret = p
  );
$$;
revoke all on function public.daily_run_secret_ok(text) from public, anon, authenticated;
grant execute on function public.daily_run_secret_ok(text) to service_role;

-- 3) 呼叫 daily-run 的小工具（排程和手動測試都用這個）
create or replace function public.daily_run_call(p_mode text) returns bigint
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://nopyhfpaykkiieudvoko.supabase.co/functions/v1/daily-run',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-run-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'daily_run_secret')),
    body := jsonb_build_object('mode', p_mode),
    timeout_milliseconds := 10000);
$$;
revoke all on function public.daily_run_call(text) from public, anon, authenticated;

-- 4) 排程
select cron.schedule('wanghome-nightly', '17 19 * * *',   $$select public.daily_run_call('nightly')$$);
select cron.schedule('wanghome-cleanup', '47 19 * * *',   $$select public.daily_run_call('cleanup')$$);
select cron.schedule('wanghome-notify',  '21 */2 * * *',  $$select public.daily_run_call('notify')$$);

-- 手動測試：select public.daily_run_call('notify');
--   幾秒後到 Edge Functions → daily-run → Logs 看結果；
--   或查呼叫狀態：select status_code, content from net._http_response order by created desc limit 5;
-- 查排程是否有跑：select jobname, status, start_time from cron.job_run_details d join cron.job j using (jobid) order by start_time desc limit 10;
-- 停掉排程：select cron.unschedule('wanghome-notify');（其他兩個同理）

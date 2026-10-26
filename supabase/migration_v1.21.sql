-- 汪喵回家 migration v1.21 — 免費額度保護與資料成長（第 9 輪檢查）
--   1. 每日寄信預算：Resend 免費版一天 100 封，而且「登入信」也走同一個帳號。
--      網站通知（目擊、確認信、會員通知、提醒）一天最多用 60 封，保留至少 40 封給登入信；
--      其中會員通知（附近走失、追蹤、到期提醒）最多用到第 40 封，目擊通知和確認信永遠有保留額度。
--   2. 定期清理：舊的寄信／通知紀錄、次數限制紀錄、已結案案件的收容所比對
--   3. 補索引：地圖目擊、最近回家、追蹤數、寵物清單等查詢
--   4. 拾獲／目擊通報 60 天自動結案；結案後不公開通報者聯絡方式
-- 可重複執行。

-- 1 ---------------------------------------------------------------------------
create table if not exists public.mail_budget_log (
  id   bigserial primary key,
  at   timestamptz not null default now(),
  kind text not null
);
create index if not exists mail_budget_log_at on public.mail_budget_log(at desc);
alter table public.mail_budget_log enable row level security;
revoke all on public.mail_budget_log from anon, authenticated;

-- 取一封寄信額度：今天（台灣時間）已寄的總數小於 p_cap 才給；同時寄信時用鎖避免超過
create or replace function public.mail_budget_take(p_kind text, p_cap int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_start timestamptz := (date_trunc('day', now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei';
begin
  perform pg_advisory_xact_lock(hashtext('mail_budget'));
  if (select count(*) from public.mail_budget_log where at >= v_start) >= p_cap then return false; end if;
  insert into public.mail_budget_log(kind) values (left(p_kind, 20));
  return true;
end $$;
revoke all on function public.mail_budget_take(text, int) from public, anon, authenticated;
grant execute on function public.mail_budget_take(text, int) to service_role;

-- 今天用了多少（給管理後台或排程看）
create or replace function public.mail_budget_today()
returns table(kind text, n bigint) language sql stable security definer set search_path = public as $$
  select kind, count(*) from public.mail_budget_log
   where at >= (date_trunc('day', now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei'
   group by kind order by 2 desc;
$$;
revoke all on function public.mail_budget_today() from public, anon, authenticated;
grant execute on function public.mail_budget_today() to service_role;

-- 2 ---------------------------------------------------------------------------
create or replace function public.retention_cleanup()
returns jsonb language plpgsql security definer set search_path = public as $$
declare a int; b int; c int; d int; e int; f int;
begin
  delete from public.notify_log where sent_at < now() - interval '60 days'; get diagnostics a = row_count;
  delete from public.rate_hits where at < now() - interval '2 days'; get diagnostics b = row_count;
  delete from public.mail_budget_log where at < now() - interval '14 days'; get diagnostics c = row_count;
  delete from public.case_mail_log where sent_at < now() - interval '60 days'; get diagnostics d = row_count;
  -- 已經找到或結案超過 30 天的案件：收容所比對結果不再需要
  -- （用找到時間／最後動態時間判斷；updated_at 每次有人瀏覽都會變，不能用）
  delete from public.shelter_matches m using public.cases k
   where m.case_id = k.id and k.status <> 'searching' and coalesce(k.found_at, k.last_activity, k.created_at) < now() - interval '30 days';
  get diagnostics e = row_count;
  -- 拾獲／目擊通報登記 60 天後自動結案（網站上承諾的「自動下架」；結案後不再公開通報者聯絡方式）
  update public.found_reports set status = 'closed' where status = 'open' and created_at < now() - interval '60 days';
  get diagnostics f = row_count;
  return jsonb_build_object('found_closed', f, 'notify_log', a, 'rate_hits', b, 'mail_budget_log', c, 'case_mail_log', d, 'shelter_matches', e);
end $$;
revoke all on function public.retention_cleanup() from public, anon, authenticated;
grant execute on function public.retention_cleanup() to service_role;

-- 3 ---------------------------------------------------------------------------
create index if not exists rate_hits_at on public.rate_hits(at);
create index if not exists sightings_confirmed_seen on public.sightings(seen_at desc) where status = 'confirmed';
create index if not exists cases_status_found_at on public.cases(status, found_at desc nulls last);
create index if not exists cases_last_activity on public.cases(last_activity desc);
create index if not exists follows_case_id on public.follows(case_id);
create index if not exists found_matches_found_id on public.found_matches(found_id);
create index if not exists pets_owner_id on public.pets(owner_id);

-- 4 ---------------------------------------------------------------------------
-- 拾獲／目擊通報結案後（已回家、已結案、或 60 天自動結案），不再公開通報者的電話和 LINE
create or replace view public.found_public with (security_invoker = false) as
select id, created_at, updated_at, species, kind, status, seen_at, city, district, place_text, lat, lng,
       breed, sex, size, colour, features, collar_desc, current_place, photos, reporter_name,
       case when phone_public and status = 'open' then reporter_phone else null end as reporter_phone,
       phone_public, case when status = 'open' then reporter_line else null end as reporter_line, notes, injury
from public.found_reports
where not hidden;
grant select on public.found_public to anon, authenticated;

select 'WangMiao migration v1.21 installed' as result;

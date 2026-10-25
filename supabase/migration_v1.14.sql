-- 汪喵回家 migration v1.14 — 即時通知信防灌爆
-- 每個案件每小時最多寄 6 封目擊通知（一般情況遠低於此）；超過的目擊會留到下一封一起寄。
-- 只有伺服器（service_role）會讀寫這張表。可重複執行。

create table if not exists public.case_mail_log (
  case_id uuid not null references public.cases(id) on delete cascade,
  sent_at timestamptz not null default now()
);
create index if not exists case_mail_log_idx on public.case_mail_log(case_id, sent_at desc);
alter table public.case_mail_log enable row level security;
revoke all on public.case_mail_log from anon, authenticated;
grant all on public.case_mail_log to service_role;

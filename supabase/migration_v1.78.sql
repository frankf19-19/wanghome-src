-- 汪喵回家 migration v1.78：通知信不重複
-- mail_sent：同一個信箱、同一隻收容動物（s:編號）或同一筆路人通報（f:編號）只會被通知一次，
-- 不論是排程重跑、標記失敗，或同一隻毛孩被登記成兩個案件
create table if not exists public.mail_sent (
  to_email text not null,
  item     text not null,
  sent_at  timestamptz not null default now(),
  primary key (to_email, item)
);
alter table public.mail_sent enable row level security;   -- 只有排程（service_role）能讀寫
grant all on public.mail_sent to service_role;
select 'WangMiao migration v1.78 installed' as result;

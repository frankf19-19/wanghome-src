-- 汪喵回家 migration v1.112 — QR 名牌：後台（notify-sighting）要能讀取、標記掃描紀錄才能通知飼主
--   v1.111 建表時沒有給 service_role 權限，所以掃描後通知送不出去。可重複執行。
grant select, update on public.pet_tag_scans to service_role;
select string_agg(privilege_type, ',' order by privilege_type) as service_role_privs
  from information_schema.role_table_grants where table_name = 'pet_tag_scans' and grantee = 'service_role';

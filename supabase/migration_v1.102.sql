-- v1.102 修正：rehomes 有 RLS 政策（v1.90）但從未 GRANT 給 authenticated，
-- 導致民眾送養刊登、我的刊登、編輯全部 403 permission denied。
-- 刪除仍維持 revoke（v1.90），內容檢查由 rehomes_guard 觸發器負責。
grant select, insert, update on public.rehomes to authenticated;
select 'ok' as v1_102,
  has_table_privilege('authenticated','public.rehomes','select') s,
  has_table_privilege('authenticated','public.rehomes','insert') i,
  has_table_privilege('authenticated','public.rehomes','update') u,
  has_table_privilege('authenticated','public.rehomes','delete') d;

-- 汪喵回家 migration v1.44 — 用登記時填的 Email 找回管理權
--   沒登入就登記、又找不到管理網址的飼主／通報者：用 Email 收驗證碼登入後，
--   把「聯絡 Email 跟這個帳號一樣、還沒有擁有者」的案件和通報綁到這個帳號。
--   Email 能收到驗證碼＝證明是本人。農業部匯入的案件不綁。可重複執行。
create or replace function public.claim_by_email()
returns jsonb language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(auth.jwt()->>'email',''))); n1 int := 0; n2 int := 0;
begin
  if auth.uid() is null or e = '' then raise exception '請先登入'; end if;
  update public.cases set owner_id = auth.uid()
   where owner_id is null and coalesce(source,'site') <> 'moa' and lower(trim(contact_email)) = e;
  get diagnostics n1 = row_count;
  update public.found_reports set owner_id = auth.uid()
   where owner_id is null and lower(trim(reporter_email)) = e;
  get diagnostics n2 = row_count;
  return jsonb_build_object('cases', n1, 'found', n2);
end $$;
revoke all on function public.claim_by_email() from public, anon;
grant execute on function public.claim_by_email() to authenticated;

select 'WangHome migration v1.44 installed' as result;

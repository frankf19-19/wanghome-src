-- 汪喵回家 migration v1.16 — 上架準備：使用者自行刪除資料
--   1. delete_my_account()：會員刪除帳號（寵物、健康紀錄、用藥、追蹤、通知紀錄一併刪除；走失案件解除綁定）
--   2. delete_case(id, token)：飼主刪除自己的走失案件（目擊、比對一併刪除）
--   3. delete_found(id, token)：通報者刪除自己的拾獲／目擊／受傷通報
--   4. 會員可刪除自己上傳的公開照片與私密檔案（刪帳號時清掉照片）
-- App Store 5.1.1(v)、Google Play 帳號刪除規定、個資法當事人權利。可重複執行。

create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception '請先登入'; end if;
  -- 走失案件／通報保留給協尋（已公開的內容），只解除和帳號的連結；本人可用管理網址另外刪除
  update public.cases set owner_id = null where owner_id = v_uid;
  update public.found_reports set owner_id = null where owner_id = v_uid;
  update public.sightings set reporter_id = null where reporter_id = v_uid;
  -- 刪除帳號：profiles、pets（含健康紀錄、用藥、打勾紀錄）、follows、notify_log 會跟著刪除
  delete from auth.users where id = v_uid;
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

create or replace function public.delete_case(p_id uuid, p_token text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_case(p_id, p_token) then raise exception '管理網址不正確'; end if;
  delete from public.cases where id = p_id;
end $$;
grant execute on function public.delete_case(uuid, text) to anon, authenticated;

create or replace function public.delete_found(p_id uuid, p_token text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_found(p_id, p_token) then raise exception '管理網址不正確'; end if;
  delete from public.found_reports where id = p_id;
end $$;
grant execute on function public.delete_found(uuid, text) to anon, authenticated;

-- 自己上傳的檔案可以自己刪（storage.objects.owner = 上傳者）
drop policy if exists "own photos delete" on storage.objects;
create policy "own photos delete" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and owner_id = (select auth.uid())::text);

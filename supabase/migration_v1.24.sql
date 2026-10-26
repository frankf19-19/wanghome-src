-- 汪喵回家 migration v1.24 — 上架前安全檢查第二輪
--   1. 寄信程式用的「每個網路位址」限流（edge function 用 service_role 呼叫，位址由程式傳入）
--   2. 寄信額度分類別上限：確認信、目擊通知各自有上限，不會互相吃光
--   3. 自動過濾：目擊被擋時記住原狀態；多檢查年齡、地區、電話欄位
--   4. 寵物照片只能上傳到自己的資料夾，並套用上傳次數限制
--   5. 拾獲管理頁不回傳送出時的網路位址、帳號編號
--   6. 被停權的人也不能修改既有內容
--   7. 刪除帳號（保留內容）時，一併清掉案件上的 Email
-- 可重複執行。

-- 1 ---------------------------------------------------------------------------
create or replace function public.edge_rate_ok(p_kind text, p_ip text, p_max int, p_window interval)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_ip text := left(coalesce(nullif(p_ip, ''), 'unknown'), 64);
begin
  perform pg_advisory_xact_lock(hashtext('edge_rate:' || p_kind || ':' || v_ip));
  if (select count(*) from public.rate_hits where kind = p_kind and ip = v_ip and at > now() - p_window) >= p_max then
    return false;
  end if;
  insert into public.rate_hits(kind, ip) values (left(p_kind, 30), v_ip);
  return true;
end $$;
revoke all on function public.edge_rate_ok(text, text, int, interval) from public, anon, authenticated;
grant execute on function public.edge_rate_ok(text, text, int, interval) to service_role;

-- 2 ---------------------------------------------------------------------------
create or replace function public.mail_budget_take(p_kind text, p_cap int, p_kind_cap int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_start timestamptz := (date_trunc('day', now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei';
begin
  perform pg_advisory_xact_lock(hashtext('mail_budget'));
  if (select count(*) from public.mail_budget_log where at >= v_start) >= p_cap then return false; end if;
  if (select count(*) from public.mail_budget_log where at >= v_start and kind = left(p_kind, 20)) >= p_kind_cap then return false; end if;
  insert into public.mail_budget_log(kind) values (left(p_kind, 20));
  return true;
end $$;
revoke all on function public.mail_budget_take(text, int, int) from public, anon, authenticated;
grant execute on function public.mail_budget_take(text, int, int) to service_role;

-- 把一封額度還回去（寄信失敗、或佔位失敗時）
create or replace function public.mail_budget_return(p_kind text)
returns void language sql security definer set search_path = public as $$
  delete from public.mail_budget_log where id = (
    select id from public.mail_budget_log where kind = left(p_kind, 20) order by at desc limit 1);
$$;
revoke all on function public.mail_budget_return(text) from public, anon, authenticated;
grant execute on function public.mail_budget_return(text) to service_role;

-- 3 ---------------------------------------------------------------------------
create or replace function public.ugc_filter() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_text text; v_type text;
begin
  if tg_table_name = 'cases' then
    v_type := 'case';
    v_text := concat_ws(' ', new.name, new.breed, new.colour, new.age_text, new.features, new.collar_desc, new.temperament, new.lost_district, new.lost_place, new.contact_name, new.contact_phone, new.contact_line, new.notes, new.found_note);
  elsif tg_table_name = 'found_reports' then
    v_type := 'found';
    v_text := concat_ws(' ', new.place_text, new.breed, new.colour, new.features, new.collar_desc, new.current_place, new.reporter_name, new.reporter_phone, new.reporter_line, new.notes, new.injury);
  else
    v_type := 'sighting';
    v_text := concat_ws(' ', new.place_text, new.direction, new.note, new.reporter_name, new.reporter_contact);
  end if;
  if not public.ugc_bad(v_text) then return new; end if;
  if tg_op = 'UPDATE' and v_type <> 'sighting' then
    -- 修改時只有「新出現」可疑字眼才處理，避免站長恢復顯示後又被藏起來
    if v_type = 'case' and public.ugc_bad(concat_ws(' ', old.name, old.breed, old.colour, old.age_text, old.features, old.collar_desc, old.temperament, old.lost_district, old.lost_place, old.contact_name, old.contact_phone, old.contact_line, old.notes, old.found_note)) then return new; end if;
    if v_type = 'found' and public.ugc_bad(concat_ws(' ', old.place_text, old.breed, old.colour, old.features, old.collar_desc, old.current_place, old.reporter_name, old.reporter_phone, old.reporter_line, old.notes, old.injury)) then return new; end if;
  end if;
  if v_type = 'sighting' then
    if tg_op = 'UPDATE' then return new; end if;   -- 目擊只在新增時檢查（飼主改備註不影響）
    new.status := 'rejected';                      -- 不顯示、也不寄給飼主
    new.status_before_hide := 'pending';           -- 站長恢復時回到「待確認」
  else
    new.hidden := true;
  end if;
  insert into public.reports (target_type, target_id, reason, note) values (v_type, new.id, 'inappropriate', '系統自動過濾：內容含可疑字眼，已先隱藏，請站長確認');
  return new;
end $$;

drop trigger if exists cases_ugc on public.cases;
create trigger cases_ugc before insert or update of name, breed, colour, age_text, features, collar_desc, temperament, lost_district, lost_place, contact_name, contact_phone, contact_line, notes, found_note
  on public.cases for each row execute function public.ugc_filter();
drop trigger if exists found_ugc on public.found_reports;
create trigger found_ugc before insert or update of place_text, breed, colour, features, collar_desc, current_place, reporter_name, reporter_phone, reporter_line, notes, injury
  on public.found_reports for each row execute function public.ugc_filter();

-- 4 ---------------------------------------------------------------------------
drop policy if exists "anon upload photos" on storage.objects;
create policy "anon upload photos" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'photos' and (
    ((storage.foldername(name))[1] in ('cases', 'found', 'sightings') and public.photo_upload_ok())
    or ((storage.foldername(name))[1] = 'pets' and auth.uid() is not null
        and (storage.foldername(name))[2] = auth.uid()::text and public.photo_upload_ok())
  ));

-- 5 ---------------------------------------------------------------------------
create or replace function public.owner_found(p_id uuid, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.found_reports;
begin
  if not public.can_manage_found(p_id, p_token) then raise exception '管理連結無效'; end if;
  select * into r from public.found_reports where id = p_id;
  return (to_jsonb(r) - 'edit_token' - 'created_ip' - 'owner_id')
         || jsonb_build_object('is_mine', r.owner_id is not null and r.owner_id = auth.uid());
end $$;

-- 6 ---------------------------------------------------------------------------
create or replace function public.ugc_guard_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('wm.skip_guard', true) = '1' then return new; end if;   -- 刪除帳號時清 Email
  if coalesce(auth.role(), '') in ('anon', 'authenticated') and not public.is_admin() and public.is_banned() then
    raise exception '因違反使用規範，這個帳號或網路已無法再修改內容。如有疑問請寫信到 service@wangmiaotw.com';
  end if;
  return new;
end $$;
drop trigger if exists cases_guard_upd on public.cases;
create trigger cases_guard_upd before update of name, breed, colour, age_text, features, collar_desc, temperament, lost_district, lost_place, contact_name, contact_phone, contact_line, contact_email, notes, photos, status, found_note
  on public.cases for each row execute function public.ugc_guard_update();
drop trigger if exists found_guard_upd on public.found_reports;
create trigger found_guard_upd before update of place_text, breed, colour, features, collar_desc, current_place, reporter_name, reporter_phone, reporter_line, notes, injury, photos, status
  on public.found_reports for each row execute function public.ugc_guard_update();
drop trigger if exists sightings_guard_upd on public.sightings;
create trigger sightings_guard_upd before update of place_text, direction, note, reporter_name, reporter_contact, photo_url
  on public.sightings for each row execute function public.ugc_guard_update();

-- 7 ---------------------------------------------------------------------------
create or replace function public.delete_my_account(p_delete_content boolean default false)
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception '請先登入'; end if;
  if p_delete_content then
    delete from public.cases where owner_id = v_uid;
    delete from public.found_reports where owner_id = v_uid;
    delete from public.sightings where reporter_id = v_uid;
  else
    perform set_config('wm.skip_guard', '1', true);
    -- 保留給協尋（已公開的內容），只解除和帳號的連結；Email 一併清掉，之後不再寄任何信
    update public.cases set owner_id = null, contact_email = null, email_verified = false, email_verify_hash = null
     where owner_id = v_uid;
    update public.found_reports set owner_id = null where owner_id = v_uid;
    update public.sightings set reporter_id = null where reporter_id = v_uid;
  end if;
  delete from auth.users where id = v_uid;
end $$;
revoke all on function public.delete_my_account(boolean) from public, anon;
grant execute on function public.delete_my_account(boolean) to authenticated;

-- 汪喵回家 migration v1.25 — 管理後台：內容管理、會員、停權名單
--   1. admin_list：列出所有走失案件／拾獲通報／目擊（含隱藏），可搜尋、篩選；管理員看得到完整聯絡方式
--   2. admin_update：管理員直接修改內容（只開放文字與狀態欄位）
--   3. admin_delete：管理員永久刪除一則內容
--   4. admin_members：會員清單（Email、加入時間、最後登入、發布數量、是否停權）
--   5. 停權名單：admin_bans、admin_unban、admin_ban_member
--   6. 站長修改內容時不觸發自動過濾
--   7. 刪除帳號（保留內容）時，拾獲通報上的 Email 也清掉
-- 只有 profiles.is_admin = true 的帳號能用。可重複執行。

-- 1 ---------------------------------------------------------------------------
create or replace function public.admin_list(p_type text, p_q text default '', p_filter text default 'all', p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare q text := '%' || coalesce(nullif(trim(p_q), ''), '') || '%'; j jsonb;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then
    select coalesce(jsonb_agg(x order by x.created_at desc), '[]') into j from (
      select c.id, c.created_at, c.status, c.hidden, c.name, c.species, c.breed, c.colour, c.lost_at, c.lost_city, c.lost_district, c.lost_place,
             c.features, c.notes, c.photos[1] as photo, c.contact_name, c.contact_phone, c.phone_public, c.contact_line, c.contact_email, c.email_verified,
             u.email as member_email, c.view_count,
             (select count(*) from public.sightings s where s.case_id = c.id) as sightings,
             (select count(*) from public.reports r where r.target_id = c.id and not r.resolved) as open_reports
        from public.cases c left join auth.users u on u.id = c.owner_id
       where (p_filter = 'all' or (p_filter = 'hidden' and c.hidden) or (p_filter in ('searching','found','closed') and c.status = p_filter and not c.hidden)
              or (p_filter = 'reported' and exists (select 1 from public.reports r where r.target_id = c.id and not r.resolved)))
         and (q = '%%' or concat_ws(' ', c.name, c.breed, c.colour, c.lost_city, c.lost_district, c.lost_place, c.contact_name, c.contact_phone, c.contact_line, c.contact_email, u.email, c.id::text) ilike q)
       order by c.created_at desc offset greatest(p_offset, 0) limit 30) x;
  elsif p_type = 'found' then
    select coalesce(jsonb_agg(x order by x.created_at desc), '[]') into j from (
      select f.id, f.created_at, f.kind, f.status, f.hidden, f.seen_at, f.city, f.district, f.place_text, f.breed, f.colour, f.features, f.notes,
             f.current_place, f.photos[1] as photo, f.reporter_name, f.reporter_phone, f.phone_public, f.reporter_line, f.reporter_email,
             u.email as member_email,
             (select count(*) from public.reports r where r.target_id = f.id and not r.resolved) as open_reports
        from public.found_reports f left join auth.users u on u.id = f.owner_id
       where (p_filter = 'all' or (p_filter = 'hidden' and f.hidden) or (p_filter in ('open','reunited','closed') and f.status = p_filter and not f.hidden)
              or (p_filter = 'reported' and exists (select 1 from public.reports r where r.target_id = f.id and not r.resolved)))
         and (q = '%%' or concat_ws(' ', f.city, f.district, f.place_text, f.breed, f.colour, f.reporter_name, f.reporter_phone, f.reporter_line, f.reporter_email, u.email, f.id::text) ilike q)
       order by f.created_at desc offset greatest(p_offset, 0) limit 30) x;
  elsif p_type = 'sighting' then
    select coalesce(jsonb_agg(x order by x.created_at desc), '[]') into j from (
      select s.id, s.created_at, s.seen_at, s.case_id, c.name as case_name, s.status, s.place_text, s.direction, s.note, s.photo_url,
             s.reporter_name, s.reporter_contact, u.email as member_email,
             (select count(*) from public.reports r where r.target_id = s.id and not r.resolved) as open_reports
        from public.sightings s join public.cases c on c.id = s.case_id left join auth.users u on u.id = s.reporter_id
       where (p_filter = 'all' or (p_filter = 'hidden' and s.status = 'rejected') or (p_filter in ('pending','confirmed') and s.status = p_filter)
              or (p_filter = 'reported' and exists (select 1 from public.reports r where r.target_id = s.id and not r.resolved)))
         and (q = '%%' or concat_ws(' ', c.name, s.place_text, s.note, s.reporter_name, s.reporter_contact, u.email, s.id::text) ilike q)
       order by s.created_at desc offset greatest(p_offset, 0) limit 30) x;
  else raise exception '類型錯誤'; end if;
  return j;
end $$;
revoke all on function public.admin_list(text, text, text, int) from public, anon;
grant execute on function public.admin_list(text, text, text, int) to authenticated;

-- 2 ---------------------------------------------------------------------------
create or replace function public.admin_update(p_type text, p_id uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then
    if p ? 'status' and p->>'status' not in ('searching','found','closed') then raise exception '狀態錯誤'; end if;
    update public.cases set
      name          = case when p ? 'name'          then left(p->>'name', 30)           else name end,
      breed         = case when p ? 'breed'         then left(p->>'breed', 50)          else breed end,
      colour        = case when p ? 'colour'        then left(p->>'colour', 50)         else colour end,
      features      = case when p ? 'features'      then left(p->>'features', 1000)     else features end,
      notes         = case when p ? 'notes'         then left(p->>'notes', 1000)        else notes end,
      lost_place    = case when p ? 'lost_place'    then left(p->>'lost_place', 200)    else lost_place end,
      contact_name  = case when p ? 'contact_name'  then left(p->>'contact_name', 50)   else contact_name end,
      contact_phone = case when p ? 'contact_phone' then left(p->>'contact_phone', 30)  else contact_phone end,
      contact_line  = case when p ? 'contact_line'  then left(p->>'contact_line', 60)   else contact_line end,
      phone_public  = case when p ? 'phone_public'  then (p->>'phone_public')::boolean  else phone_public end,
      status        = coalesce(p->>'status', status),
      found_at      = case when p->>'status' = 'found' and found_at is null then now()
                           when p->>'status' = 'searching' then null else found_at end,
      updated_at    = now()
    where id = p_id;
  elsif p_type = 'found' then
    if p ? 'status' and p->>'status' not in ('open','reunited','closed') then raise exception '狀態錯誤'; end if;
    update public.found_reports set
      place_text     = case when p ? 'place_text'     then left(p->>'place_text', 200)     else place_text end,
      breed          = case when p ? 'breed'          then left(p->>'breed', 50)           else breed end,
      colour         = case when p ? 'colour'         then left(p->>'colour', 50)          else colour end,
      features       = case when p ? 'features'       then left(p->>'features', 1000)      else features end,
      notes          = case when p ? 'notes'          then left(p->>'notes', 1000)         else notes end,
      current_place  = case when p ? 'current_place'  then left(p->>'current_place', 200)  else current_place end,
      reporter_name  = case when p ? 'reporter_name'  then left(p->>'reporter_name', 50)   else reporter_name end,
      reporter_phone = case when p ? 'reporter_phone' then left(p->>'reporter_phone', 30)  else reporter_phone end,
      reporter_line  = case when p ? 'reporter_line'  then left(p->>'reporter_line', 60)   else reporter_line end,
      phone_public   = case when p ? 'phone_public'   then (p->>'phone_public')::boolean   else phone_public end,
      status         = coalesce(p->>'status', status),
      updated_at     = now()
    where id = p_id;
  elsif p_type = 'sighting' then
    if p ? 'status' and p->>'status' not in ('pending','confirmed','rejected') then raise exception '狀態錯誤'; end if;
    update public.sightings set
      place_text    = case when p ? 'place_text'    then left(p->>'place_text', 200)    else place_text end,
      direction     = case when p ? 'direction'     then left(p->>'direction', 20)      else direction end,
      note          = case when p ? 'note'          then left(p->>'note', 1000)          else note end,
      reporter_name = case when p ? 'reporter_name' then left(p->>'reporter_name', 50)  else reporter_name end,
      -- 狀態改成「退回」時記住原狀態；改成其他狀態時清掉隱藏紀錄（不然飼主之後無法再處理這則目擊）
      status_before_hide = case when p->>'status' = 'rejected' and status <> 'rejected' then status
                                when p ? 'status' and p->>'status' <> 'rejected' then null
                                else status_before_hide end,
      status        = coalesce(p->>'status', status)
    where id = p_id;
  else raise exception '類型錯誤'; end if;
  if not found then raise exception '找不到這則內容'; end if;
end $$;
revoke all on function public.admin_update(text, uuid, jsonb) from public, anon;
grant execute on function public.admin_update(text, uuid, jsonb) to authenticated;

-- 3 ---------------------------------------------------------------------------
create or replace function public.admin_delete(p_type text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then
    -- 案件底下的目擊會一起刪除：它們的檢舉也一併結案
    update public.reports set resolved = true, resolved_at = now()
     where not resolved and target_id in (select id from public.sightings where case_id = p_id);
    delete from public.cases where id = p_id;
  elsif p_type = 'found' then delete from public.found_reports where id = p_id;
  elsif p_type = 'sighting' then delete from public.sightings where id = p_id;
  else raise exception '類型錯誤'; end if;
  if not found then raise exception '找不到這則內容'; end if;
  update public.reports set resolved = true, resolved_at = now() where target_id = p_id and not resolved;
end $$;
revoke all on function public.admin_delete(text, uuid) from public, anon;
grant execute on function public.admin_delete(text, uuid) to authenticated;

-- 4 ---------------------------------------------------------------------------
create or replace function public.admin_members(p_q text default '', p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare q text := '%' || coalesce(nullif(trim(p_q), ''), '') || '%'; j jsonb;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  select coalesce(jsonb_agg(x order by x.created_at desc), '[]') into j from (
    select u.id, u.email, u.created_at, u.last_sign_in_at, p.display_name, coalesce(p.is_admin, false) as is_admin,
           (select count(*) from public.cases c where c.owner_id = u.id) as cases,
           (select count(*) from public.found_reports f where f.owner_id = u.id) as founds,
           (select count(*) from public.sightings s where s.reporter_id = u.id) as sightings,
           (select count(*) from public.pets t where t.owner_id = u.id) as pets,
           exists (select 1 from public.bans b where b.user_id = u.id and (b.expires_at is null or b.expires_at > now())) as banned
      from auth.users u left join public.profiles p on p.id = u.id
     where q = '%%' or concat_ws(' ', u.email, p.display_name, u.id::text) ilike q
     order by u.created_at desc offset greatest(p_offset, 0) limit 50) x;
  return j;
end $$;
revoke all on function public.admin_members(text, int) from public, anon;
grant execute on function public.admin_members(text, int) to authenticated;

-- 5 ---------------------------------------------------------------------------
create or replace function public.admin_bans()
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare j jsonb;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  select coalesce(jsonb_agg(x order by x.created_at desc), '[]') into j from (
    select b.id, b.created_at, b.reason, b.expires_at, (b.ip is not null) as has_ip, u.email
      from public.bans b left join auth.users u on u.id = b.user_id
     where b.expires_at is null or b.expires_at > now()
     order by b.created_at desc limit 200) x;
  return j;
end $$;
revoke all on function public.admin_bans() from public, anon;
grant execute on function public.admin_bans() to authenticated;

create or replace function public.admin_unban(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  delete from public.bans where id = p_id;
end $$;
revoke all on function public.admin_unban(uuid) from public, anon;
grant execute on function public.admin_unban(uuid) to authenticated;

create or replace function public.admin_ban_member(p_user uuid, p_reason text default null, p_days int default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_user = auth.uid() then raise exception '不能停權自己'; end if;
  insert into public.bans (user_id, reason, expires_at)
  values (p_user, left(p_reason, 200), case when p_days is not null then now() + make_interval(days => p_days) end);
end $$;
revoke all on function public.admin_ban_member(uuid, text, int) from public, anon;
grant execute on function public.admin_ban_member(uuid, text, int) to authenticated;

-- 6 ---------------------------------------------------------------------------
-- 自動過濾：站長自己修改的內容不檢查（例如加上「請勿先匯款」提醒）
create or replace function public.ugc_filter() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_text text; v_type text;
begin
  if public.is_admin() then return new; end if;   -- 站長修改的內容不再自動過濾
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


-- 7 ---------------------------------------------------------------------------
-- 刪除帳號（保留內容）：拾獲通報上的 Email 也一起清掉
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
    update public.found_reports set owner_id = null, reporter_email = null where owner_id = v_uid;
    update public.sightings set reporter_id = null where reporter_id = v_uid;
  end if;
  delete from auth.users where id = v_uid;
end $$;

-- 站長帳號（只有這個帳號能進管理後台）
update public.profiles set is_admin = true where id = (select id from auth.users where email = 'frankccc199@gmail.com');

select 'v1.25 ok' as result, (select count(*) from public.profiles where is_admin) as admins;

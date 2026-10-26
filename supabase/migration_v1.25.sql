-- 汪喵回家 migration v1.25 — 管理後台：內容管理、會員、停權名單
--   1. admin_list：列出所有走失案件／拾獲通報／目擊（含隱藏），可搜尋、篩選；管理員看得到完整聯絡方式
--   2. admin_update：管理員直接修改內容（只開放文字與狀態欄位）
--   3. admin_delete：管理員永久刪除一則內容
--   4. admin_members：會員清單（Email、加入時間、最後登入、發布數量、是否停權）
--   5. 停權名單：admin_bans、admin_unban、admin_ban_member
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
      contact_line  = case when p ? 'contact_line'  then left(p->>'contact_line', 50)   else contact_line end,
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
      reporter_line  = case when p ? 'reporter_line'  then left(p->>'reporter_line', 50)   else reporter_line end,
      phone_public   = case when p ? 'phone_public'   then (p->>'phone_public')::boolean   else phone_public end,
      status         = coalesce(p->>'status', status),
      updated_at     = now()
    where id = p_id;
  elsif p_type = 'sighting' then
    if p ? 'status' and p->>'status' not in ('pending','confirmed','rejected') then raise exception '狀態錯誤'; end if;
    update public.sightings set
      place_text    = case when p ? 'place_text'    then left(p->>'place_text', 200)    else place_text end,
      direction     = case when p ? 'direction'     then left(p->>'direction', 20)      else direction end,
      note          = case when p ? 'note'          then left(p->>'note', 500)          else note end,
      reporter_name = case when p ? 'reporter_name' then left(p->>'reporter_name', 50)  else reporter_name end,
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
  if p_type = 'case' then delete from public.cases where id = p_id;
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

-- 站長帳號（只有這個帳號能進管理後台）
update public.profiles set is_admin = true where id = (select id from auth.users where email = 'frankccc199@gmail.com');

select 'v1.25 ok' as result, (select count(*) from public.profiles where is_admin) as admins;

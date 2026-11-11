-- 汪喵回家 migration v1.70：管理員可以調整案件照片順序（admin_update 多收 photos）

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
      photos        = case when p ? 'photos' then coalesce((select array_agg(x) from jsonb_array_elements_text(p->'photos') x), '{}') else photos end,
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

select 'WangMiao migration v1.70 installed' as result;

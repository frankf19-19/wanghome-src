-- 汪喵回家 migration v1.69：找到的毛孩 = 回家故事
-- 1) cases.found_photo：飼主上傳的團圓照（同一張也放在 photos 第一張，照片清理不會誤刪）
-- 2) cases_public 多一欄 found_photo
-- 3) update_case 可以存 found_photo；改回協尋中會清掉
-- 4) reunite_targets：追蹤的案件回家了 → 通知追蹤的人（daily-run 推播用）

alter table public.cases add column if not exists found_photo text;
alter table public.cases drop constraint if exists cases_found_photo_ok;
alter table public.cases add constraint cases_found_photo_ok check (public.photo_url_ok(found_photo)) not valid;

create or replace view public.cases_public with (security_invoker = false) as
select id, created_at, updated_at, last_activity, status, name, species, breed, sex, size,
       colour, age_text, features, has_chip, chip_last4, neutered, collar_desc, temperament,
       lost_at, lost_city, lost_district, lost_place, lost_lat, lost_lng, photos,
       contact_name,
       case when phone_public then contact_phone else null end as contact_phone,
       phone_public, contact_line, reward, notes, found_at, found_note, found_method, view_count,
       (select count(*) from public.sightings s where s.case_id = c.id and s.status='confirmed') as sighting_count,
       (select max(seen_at) from public.sightings s where s.case_id = c.id and s.status='confirmed') as last_seen_at,
       left(md5('wm-poster:' || coalesce(c.owner_id::text, 'c:' || c.id::text)), 12) as poster,
       (select count(*) from public.sightings s where s.case_id = c.id and s.status = 'pending' and s.status_before_hide is null) as pending_count,
       c.source,
       c.found_photo
from public.cases c
where not c.hidden;
grant select on public.cases_public to anon, authenticated;

create or replace function public.update_case(p_id uuid, p_token text, p jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.can_manage_case(p_id, p_token) then raise exception '管理連結無效'; end if;
  -- 改聯絡信箱：每個 IP 每天 3 次，全站每小時 200 次
  if p ? 'contact_email' and nullif(btrim(p->>'contact_email'), '') is distinct from
     (select nullif(btrim(contact_email), '') from public.cases where id = p_id) then
    perform public.rate_check('email_change', 3, interval '1 day', 200, interval '1 hour');
  end if;
  update public.cases set
    status        = coalesce(nullif(p->>'status',''), status),
    name          = coalesce(p->>'name', name),
    breed         = coalesce(p->>'breed', breed),
    colour        = coalesce(p->>'colour', colour),
    features      = coalesce(p->>'features', features),
    collar_desc   = coalesce(p->>'collar_desc', collar_desc),
    temperament   = coalesce(p->>'temperament', temperament),
    lost_place    = coalesce(p->>'lost_place', lost_place),
    contact_name  = coalesce(p->>'contact_name', contact_name),
    contact_phone = coalesce(p->>'contact_phone', contact_phone),
    phone_public  = coalesce((p->>'phone_public')::boolean, phone_public),
    contact_email = coalesce(p->>'contact_email', contact_email),
    contact_line  = coalesce(p->>'contact_line', contact_line),
    reward        = coalesce((p->>'reward')::integer, reward),
    notes         = coalesce(p->>'notes', notes),
    photos        = case when p ? 'photos'
                      then coalesce((select array_agg(x) from jsonb_array_elements_text(p->'photos') x), '{}')
                      else photos end,
    found_at      = case when p->>'status' = 'found' then coalesce(found_at, now()) when p->>'status' = 'searching' then null else found_at end,
    found_note    = case when p->>'status' = 'searching' then null else coalesce(p->>'found_note', found_note) end,
    found_method  = case when p->>'status' = 'searching' then null else coalesce(p->>'found_method', found_method) end,
    found_photo   = case when p->>'status' = 'searching' then null
                         when p ? 'found_photo' then nullif(p->>'found_photo', '')
                         else found_photo end,
    updated_at    = now(),
    last_activity = now()
  where id = p_id;
end $$;
grant execute on function public.update_case(uuid,text,jsonb) to anon, authenticated;

-- 追蹤的案件回家了：p_hours 小時內改成「已回家」、還沒通知過的追蹤者（不含飼主自己）
create or replace function public.reunite_targets(p_hours integer default 26)
returns table (user_id uuid, case_id uuid, case_name text, found_at timestamptz)
language sql security definer set search_path = public as $$
  select f.user_id, c.id, c.name, c.found_at
  from public.follows f
  join public.cases c on c.id = f.case_id
  where c.status = 'found' and not c.hidden
    and c.found_at > now() - make_interval(hours => greatest(1, least(p_hours, 168)))
    and f.user_id is distinct from c.owner_id
    and not exists (select 1 from public.notify_log l where l.user_id = f.user_id and l.kind = 'reunite' and l.ref_id = c.id);
$$;
revoke all on function public.reunite_targets(integer) from public, anon, authenticated;
grant execute on function public.reunite_targets(integer) to service_role;

select 'WangMiao migration v1.69 installed' as result;

-- 汪喵回家 migration v1.45 — 安全性與資料正確性修正（可重複執行）
--   1. 收容所照片只能由網站伺服器存（不再讓任何人上傳，避免假照片）
--   2. 農業部匯入的舊申報不會被當成「家附近新走失」通知
--   3. 農業部申報重新開啟時，清掉「已撤銷」的結案說明
--   4. 用 Email 接手案件：帳號的 Email 必須是驗證過的

-- 1
drop policy if exists "shelter photo upload" on storage.objects;
revoke execute on function public.set_match_photo(text) from public, anon, authenticated;
grant execute on function public.set_match_photo(text) to service_role;

-- 2
create or replace function public.nearby_targets(p_hours integer default 26)
returns table(user_id uuid, email text, case_id uuid, case_name text, species text, lost_city text,
              lost_district text, lost_place text, distance_km double precision)
language sql stable security definer set search_path = public, auth as $$
  select p.id, u.email::text, c.id, c.name, c.species, c.lost_city, c.lost_district, c.lost_place,
         6371 * 2 * asin(sqrt(power(sin(radians(c.lost_lat - p.home_lat)/2),2) +
           cos(radians(p.home_lat)) * cos(radians(c.lost_lat)) * power(sin(radians(c.lost_lng - p.home_lng)/2),2))) as d
  from public.profiles p
  join auth.users u on u.id = p.id
  join public.cases c on c.status = 'searching' and c.lost_lat is not null and not c.hidden
       and (c.email_verified or c.owner_id is not null or c.source = 'moa')
       and (coalesce(c.source,'site') <> 'moa' or c.lost_at > now() - interval '3 days')   -- 農業部：只通知最近 3 天走失的
       and c.created_at < now() - interval '30 minutes'
       and c.created_at > now() - make_interval(hours => p_hours)
       and (p.notify_species = 'all' or p.notify_species = c.species)
       and (c.owner_id is null or c.owner_id <> p.id)
  where p.notify_enabled and p.home_lat is not null and u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = p.id and l.kind = 'nearby' and l.ref_id = c.id)
    and 6371 * 2 * asin(sqrt(power(sin(radians(c.lost_lat - p.home_lat)/2),2) +
           cos(radians(p.home_lat)) * cos(radians(c.lost_lat)) * power(sin(radians(c.lost_lng - p.home_lng)/2),2))) <= p.home_radius_km;
$$;
revoke all on function public.nearby_targets(integer) from public, anon, authenticated;
grant execute on function public.nearby_targets(integer) to service_role;

-- 3：重新開啟時清掉結案時間和說明（用觸發器，不用改匯入函式）
create or replace function public.moa_reopen_clear() returns trigger language plpgsql as $$
begin
  if new.source = 'moa' and old.status = 'closed' and new.status = 'searching' then
    new.found_at := null; new.found_note := null;
  end if;
  return new;
end $$;
drop trigger if exists cases_moa_reopen on public.cases;
create trigger cases_moa_reopen before update of status on public.cases
  for each row execute function public.moa_reopen_clear();

-- 4
create or replace function public.claim_by_email()
returns jsonb language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(auth.jwt()->>'email',''))); n1 int := 0; n2 int := 0;
begin
  if auth.uid() is null or e = '' then raise exception '請先登入'; end if;
  if not exists (select 1 from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null and lower(u.email) = e) then
    raise exception 'Email 還沒驗證';
  end if;
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

select 'WangHome migration v1.45 installed' as result;

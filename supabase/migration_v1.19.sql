-- 汪喵回家 migration v1.19 — 安全加強（第 8 輪檢查）
--   1. 次數限制：IPv6 以 /64 網段計算；拿不到 IP 的請求共用同一個額度（不再直接放行）
--   2. 確認信：換信箱不會重設冷卻時間；改信箱要限次數；寄信紀錄分類（確認信另計上限）
--   3. 收容所比對：非飼主送來的資料嚴格過濾（避免把詐騙電話塞進公開頁）；所有人都有每案上限
--   4. 附近走失通知：只寄已確認信箱或會員登記、且登記超過 30 分鐘的案件
--   5. 公開照片上傳：單檔上限 2MB，並限制上傳次數
--   6. 瀏覽數：限制灌水
--   7. Email 格式檢查；照片網址檢查正式啟用（有舊資料不符合時先跳過）
-- 可重複執行。

-- 1 ---------------------------------------------------------------------------
create or replace function public.client_ip() returns text
language plpgsql stable set search_path = public as $$
declare s text := nullif(btrim(current_setting('request.headers', true)::json->>'cf-connecting-ip'), ''); i inet;
begin
  if s is null then return 'unknown'; end if;
  begin i := s::inet; exception when others then return 'unknown'; end;
  -- IPv6：一般家用網路就有一整個 /64 網段，以網段計算才擋得住換位址
  return case when family(i) = 6 then network(set_masklen(i, 64))::text else host(i) end;
end $$;
revoke all on function public.client_ip() from public, anon, authenticated;

create or replace function public.rate_check(p_kind text, p_per_ip int, p_win interval, p_global int, p_gwin interval)
returns void language plpgsql security definer set search_path = public as $$
declare v_ip text := public.client_ip();
begin
  if (select count(*) from public.rate_hits where kind = p_kind and at > now() - p_gwin) >= p_global then
    raise exception '目前使用的人很多，請過幾分鐘再試';
  end if;
  if (select count(*) from public.rate_hits where kind = p_kind and ip = v_ip and at > now() - p_win) >= p_per_ip then
    raise exception '你剛剛送出太多次了，請過一會兒再試';
  end if;
  insert into public.rate_hits(kind, ip) values (p_kind, v_ip);
  if random() < 0.02 then delete from public.rate_hits where at < now() - interval '2 days'; end if;
end $$;
revoke all on function public.rate_check(text,int,interval,int,interval) from public, anon, authenticated;

-- 不丟錯誤的版本：超過就回 false（給上傳照片、瀏覽數用）
create or replace function public.rate_ok(p_kind text, p_per_ip int, p_win interval, p_global int, p_gwin interval)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_ip text := public.client_ip();
begin
  if (select count(*) from public.rate_hits where kind = p_kind and at > now() - p_gwin) >= p_global then return false; end if;
  if (select count(*) from public.rate_hits where kind = p_kind and ip = v_ip and at > now() - p_win) >= p_per_ip then return false; end if;
  insert into public.rate_hits(kind, ip) values (p_kind, v_ip);
  return true;
end $$;
revoke all on function public.rate_ok(text,int,interval,int,interval) from public, anon, authenticated;

-- 2 ---------------------------------------------------------------------------
create or replace function public.case_email_verify() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare v_mail text;
begin
  if tg_op = 'INSERT' or new.contact_email is distinct from old.contact_email then
    new.email_verified := false;
    new.email_verify_hash := null;
    -- 不重設 email_verify_sent_at：換信箱也要等冷卻時間，避免被拿來連續寄信給不同人
    if new.contact_email is not null and auth.uid() is not null
       and (new.owner_id = auth.uid() or tg_op = 'INSERT') then
      select email into v_mail from auth.users where id = auth.uid();
      if v_mail is not null and lower(btrim(v_mail)) = lower(btrim(new.contact_email)) then
        new.email_verified := true;
      end if;
    end if;
  end if;
  return new;
end $$;

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
    found_at      = case when p->>'status' = 'found' then coalesce(found_at, now()) else found_at end,
    found_note    = coalesce(p->>'found_note', found_note),
    found_method  = coalesce(p->>'found_method', found_method),
    updated_at    = now(),
    last_activity = now()
  where id = p_id;
end $$;
grant execute on function public.update_case(uuid,text,jsonb) to anon, authenticated;

alter table public.case_mail_log add column if not exists kind text not null default 'notify';
create index if not exists case_mail_log_kind_idx on public.case_mail_log(kind, sent_at desc);

-- 3 ---------------------------------------------------------------------------
create or replace function public.report_shelter_matches(p_case uuid, p_rows jsonb, p_token text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_n integer := 0;
  r jsonb;
  v_trusted boolean := public.can_manage_case(p_case, p_token);
  v_name text; v_aid text; v_sub text;
  -- 非飼主送來的文字欄位：有數字、網址、LINE、@ 就不收（防止塞電話或聯絡方式）
  bad constant text := '([0-9０-９]|http|line|www|@|ｌｉｎｅ)';
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 30 then
    raise exception '資料格式錯誤';
  end if;
  if not exists (select 1 from public.cases where id = p_case and status = 'searching' and not hidden) then
    return 0;
  end if;
  if (select count(*) from public.shelter_matches where case_id = p_case) >= (case when v_trusted then 300 else 60 end) then
    return 0;
  end if;
  if v_trusted then perform public.rate_check('shelter_owner', 30, interval '10 minutes', 3000, interval '10 minutes');
  else perform public.rate_check('shelter', 60, interval '10 minutes', 3000, interval '10 minutes'); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_aid := left(r->>'animal_id', 30);
    v_sub := left(r->>'animal_subid', 40);
    v_name := left(r->>'shelter_name', 60);
    if not v_trusted then
      if coalesce(v_aid, '') !~ '^[0-9]{1,15}$' or coalesce(v_sub, '') !~ '^[A-Z0-9]{5,25}$' then continue; end if;
      if v_name ~* bad then v_name := null; end if;
    end if;
    insert into public.shelter_matches (
      case_id, animal_id, animal_subid, shelter_name, shelter_tel, shelter_address, found_place,
      colour, bodytype, sex, age, variety, photo_url, open_date, score
    ) values (
      p_case, v_aid, v_sub, v_name,
      case when v_trusted then left(r->>'shelter_tel', 30) end,
      case when v_trusted then left(r->>'shelter_address', 120) end,
      case when v_trusted then left(r->>'found_place', 120) end,
      case when v_trusted or coalesce(r->>'colour','') !~* bad then left(r->>'colour', 20) end,
      case when v_trusted or coalesce(r->>'bodytype','') ~ '^(SMALL|MEDIUM|BIG)?$' then left(r->>'bodytype', 10) end,
      case when v_trusted or coalesce(r->>'sex','') ~ '^[MFN]?$' then left(r->>'sex', 10) end,
      case when v_trusted or coalesce(r->>'age','') ~ '^(CHILD|ADULT)?$' then left(r->>'age', 10) end,
      case when v_trusted or coalesce(r->>'variety','') !~* bad then left(r->>'variety', 30) end,
      case when r->>'photo_url' like 'https://www.pet.gov.tw/%' and r->>'photo_url' !~ '[\s''"()<>\\]' then left(r->>'photo_url', 200) else null end,
      case when r->>'open_date' ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'open_date')::date else null end,
      greatest(0, least(case when v_trusted then 100 else 60 end, coalesce((r->>'score')::integer, 0)))
    )
    on conflict (case_id, animal_id) do update set
      shelter_tel = coalesce(excluded.shelter_tel, public.shelter_matches.shelter_tel),
      shelter_address = coalesce(excluded.shelter_address, public.shelter_matches.shelter_address),
      found_place = coalesce(excluded.found_place, public.shelter_matches.found_place),
      shelter_name = coalesce(excluded.shelter_name, public.shelter_matches.shelter_name)
      where v_trusted;
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;
grant execute on function public.report_shelter_matches(uuid, jsonb, text) to anon, authenticated;

-- 4 ---------------------------------------------------------------------------
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
       and (c.email_verified or c.owner_id is not null)          -- 有確認過信箱或是會員登記的才通知
       and c.created_at < now() - interval '30 minutes'           -- 剛登記就刪掉的灌水案件不會寄出
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

-- 5 ---------------------------------------------------------------------------
update storage.buckets set file_size_limit = 2097152 where id = 'photos';   -- 網站會先壓縮成 1280px，2MB 綽綽有餘

create or replace function public.photo_upload_ok() returns boolean
language sql volatile security definer set search_path = public as $$
  -- 每個 IP 每小時 60 張（一件登記最多 4 張照片＋縮圖＝8 個檔），全站每小時 1500 張
  select public.rate_ok('photo', 60, interval '1 hour', 1500, interval '1 hour');
$$;
revoke all on function public.photo_upload_ok() from public;
grant execute on function public.photo_upload_ok() to anon, authenticated;

drop policy if exists "anon upload photos" on storage.objects;
create policy "anon upload photos" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'photos' and (
    ((storage.foldername(name))[1] in ('cases', 'found', 'sightings') and public.photo_upload_ok())
    or ((storage.foldername(name))[1] = 'pets' and auth.uid() is not null)
  ));

-- 6 ---------------------------------------------------------------------------
create or replace function public.bump_view(p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.rate_ok('view', 120, interval '1 hour', 20000, interval '1 hour') then
    update public.cases set view_count = view_count + 1 where id = p_id;
  end if;
end $$;
grant execute on function public.bump_view(uuid) to anon, authenticated;

-- 7 ---------------------------------------------------------------------------
-- Email 格式：明顯不是 Email 的舊資料先清掉（含逗號、空白、角括號或沒有 @）
update public.cases set contact_email = null
 where coalesce(contact_email, '') <> '' and contact_email !~* '^[^@\s,;<>"]+@[^@\s,;<>"]+\.[a-z]{2,}$';
alter table public.cases drop constraint if exists cases_email_ok;
alter table public.cases add constraint cases_email_ok
  check (coalesce(contact_email, '') = '' or contact_email ~* '^[^@\s,;<>"]+@[^@\s,;<>"]+\.[a-z]{2,}$');

-- 照片網址檢查：舊資料都符合才正式啟用（不符合的話只發通知，不會中斷）
do $$ begin
  if not exists (select 1 from public.cases where not public.photo_urls_ok(photos)) then
    alter table public.cases validate constraint cases_photos_ok;
  else raise notice 'cases 有照片網址不符合，暫不啟用'; end if;
  if not exists (select 1 from public.found_reports where not public.photo_urls_ok(photos)) then
    alter table public.found_reports validate constraint found_photos_ok;
  else raise notice 'found_reports 有照片網址不符合，暫不啟用'; end if;
  if not exists (select 1 from public.pets where not public.photo_urls_ok(photos)) then
    alter table public.pets validate constraint pets_photos_ok;
  else raise notice 'pets 有照片網址不符合，暫不啟用'; end if;
end $$;

select 'WangMiao migration v1.19 installed' as result;

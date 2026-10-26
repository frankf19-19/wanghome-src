-- 汪喵回家 migration v1.26 — 協尋流程修正
--   1. 收容所比對：網友瀏覽時送來的性別、體型、年紀（中文）不再被擋掉；之後再比對到同一隻會補齊欄位、分數取較高
--   2. 追蹤通知：以「飼主確認的時間」判斷，晚確認的目擊也會通知追蹤的人
--   3. 目擊回報：只能回報給「協尋中、沒有隱藏」的案件
-- 可重複執行。

-- 1 ---------------------------------------------------------------------------
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
      case when v_trusted or coalesce(r->>'bodytype','') ~ '^(SMALL|MEDIUM|BIG|小型|中型|大型)?$' then left(r->>'bodytype', 10) end,
      case when v_trusted or coalesce(r->>'sex','') ~ '^([MFN]|公|母|不明)?$' then left(r->>'sex', 10) end,
      case when v_trusted or coalesce(r->>'age','') ~ '^(CHILD|ADULT|幼犬|幼貓|成犬|成貓)?$' then left(r->>'age', 10) end,
      case when v_trusted or coalesce(r->>'variety','') !~* bad then left(r->>'variety', 30) end,
      case when r->>'photo_url' like 'https://www.pet.gov.tw/%' and r->>'photo_url' !~ '[\s''"()<>\\]' then left(r->>'photo_url', 200) else null end,
      case when r->>'open_date' ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'open_date')::date else null end,
      greatest(0, least(case when v_trusted then 100 else 60 end, coalesce((r->>'score')::integer, 0)))
    )
    on conflict (case_id, animal_id) do update set
      shelter_tel = case when v_trusted then coalesce(excluded.shelter_tel, public.shelter_matches.shelter_tel) else public.shelter_matches.shelter_tel end,
      shelter_address = case when v_trusted then coalesce(excluded.shelter_address, public.shelter_matches.shelter_address) else public.shelter_matches.shelter_address end,
      found_place = case when v_trusted then coalesce(excluded.found_place, public.shelter_matches.found_place) else public.shelter_matches.found_place end,
      shelter_name = case when v_trusted then coalesce(excluded.shelter_name, public.shelter_matches.shelter_name) else public.shelter_matches.shelter_name end,
      -- 之前缺的欄位補上（舊版網頁送來的性別／體型／年紀被擋掉了）；分數取較高的
      sex = case when v_trusted then coalesce(excluded.sex, public.shelter_matches.sex) else coalesce(public.shelter_matches.sex, excluded.sex) end,
      bodytype = case when v_trusted then coalesce(excluded.bodytype, public.shelter_matches.bodytype) else coalesce(public.shelter_matches.bodytype, excluded.bodytype) end,
      age = case when v_trusted then coalesce(excluded.age, public.shelter_matches.age) else coalesce(public.shelter_matches.age, excluded.age) end,
      score = greatest(public.shelter_matches.score, excluded.score);
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;
grant execute on function public.report_shelter_matches(uuid, jsonb, text) to anon, authenticated;

-- 2 ---------------------------------------------------------------------------
alter table public.sightings add column if not exists confirmed_at timestamptz;
revoke update (confirmed_at) on public.sightings from anon, authenticated;

create or replace function public.set_sighting_status(p_case uuid, p_sighting uuid, p_token text, p_status text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_status not in ('pending','confirmed','rejected') then raise exception '狀態錯誤'; end if;
  if not public.can_manage_case(p_case, p_token) then raise exception '管理連結無效'; end if;
  if exists (select 1 from public.sightings where id = p_sighting and status_before_hide is not null) then
    raise exception '這則目擊已被網站管理員隱藏，無法更改';
  end if;
  update public.sightings set status = p_status,
         confirmed_at = case when p_status = 'confirmed' and status <> 'confirmed' then now()
                             when p_status = 'confirmed' then confirmed_at else null end
   where id = p_sighting and case_id = p_case;
end $$;

create or replace function public.follow_targets(p_hours integer default 26)
returns table(user_id uuid, email text, case_id uuid, case_name text, sighting_id uuid, seen_at timestamptz, place_text text)
language sql stable security definer set search_path = public, auth as $$
  select f.user_id, u.email::text, c.id, c.name, s.id, s.seen_at, s.place_text
  from public.follows f
  join public.profiles p on p.id = f.user_id and p.notify_follow
  join auth.users u on u.id = f.user_id
  join public.cases c on c.id = f.case_id and c.status = 'searching' and not c.hidden
  join public.sightings s on s.case_id = c.id and s.status = 'confirmed'
       and coalesce(s.confirmed_at, s.created_at) > now() - make_interval(hours => p_hours)
  where u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = f.user_id and l.kind = 'follow' and l.ref_id = s.id);
$$;
revoke all on function public.follow_targets(integer) from public, anon, authenticated;
grant execute on function public.follow_targets(integer) to service_role;

-- 3 ---------------------------------------------------------------------------
create or replace function public.limit_sightings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.cases where id = new.case_id and status = 'searching' and not hidden) then
    raise exception '這個案件已經結束協尋，無法再回報目擊';
  end if;
  if (select count(*) from public.sightings where case_id = new.case_id and created_at > now() - interval '10 minutes') >= 60 then
    raise exception '這個案件短時間內回報太多次，請稍後再試';
  end if;
  perform public.rate_check('sighting', 20, interval '10 minutes', 1000, interval '10 minutes');
  new.created_at := now();
  new.status := 'pending';
  new.notified := false;
  new.reporter_id := auth.uid();
  new.owner_note := null;
  new.status_before_hide := null;
  new.confirmed_at := null;
  return new;
end $$;

select 'v1.26 ok' as result;

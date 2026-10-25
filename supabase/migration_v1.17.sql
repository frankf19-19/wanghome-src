-- 汪喵回家 migration v1.17 — 防濫用加固
--   1. 每個人（IP）各自的送出次數上限，不再只有「全站上限」（避免一個人灌爆讓大家都不能用）
--   2. 飼主 Email 要先點確認信，網站才會寄通知（避免有人拿別人的信箱登記，讓網站狂寄信）
--   3. 檢舉：同一個人對同一則內容只記一次
--   4. 收容所比對：非飼主送來的筆數設上限；被隱藏的案件不公開比對結果
--   5. 飼主不能把管理員隱藏的目擊改回顯示
--   6. 補上欄位長度限制、找到方式只能選固定選項
--   7. 公開照片不能被列出清單（照片網址照常可以看）；會員只能看到／刪除自己上傳的
-- 可重複執行。

-- 1 ---------------------------------------------------------------------------
create table if not exists public.rate_hits (
  kind text not null,
  ip   text not null,
  at   timestamptz not null default now()
);
create index if not exists rate_hits_idx on public.rate_hits(kind, ip, at desc);
create index if not exists rate_hits_kind_at on public.rate_hits(kind, at desc);
alter table public.rate_hits enable row level security;
revoke all on public.rate_hits from anon, authenticated;

-- 送出者 IP：優先用 Cloudflare 填的 cf-connecting-ip（使用者偽造不了）
create or replace function public.client_ip() returns text
language sql stable set search_path = public as $$
  select coalesce(
    nullif(btrim(current_setting('request.headers', true)::json->>'cf-connecting-ip'), ''),
    nullif(btrim(current_setting('request.headers', true)::json->>'x-real-ip'), ''),
    nullif(btrim(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1)), ''),
    'unknown');
$$;

create or replace function public.rate_check(p_kind text, p_per_ip int, p_win interval, p_global int, p_gwin interval)
returns void language plpgsql security definer set search_path = public as $$
declare v_ip text := public.client_ip();
begin
  if (select count(*) from public.rate_hits where kind = p_kind and at > now() - p_gwin) >= p_global then
    raise exception '目前使用的人很多，請過幾分鐘再試';
  end if;
  if v_ip <> 'unknown' and (select count(*) from public.rate_hits where kind = p_kind and ip = v_ip and at > now() - p_win) >= p_per_ip then
    raise exception '你剛剛送出太多次了，請過一會兒再試';
  end if;
  insert into public.rate_hits(kind, ip) values (p_kind, v_ip);
  if random() < 0.02 then delete from public.rate_hits where at < now() - interval '2 days'; end if;
end $$;
revoke all on function public.rate_check(text,int,interval,int,interval) from public, anon, authenticated;
revoke all on function public.client_ip() from public, anon, authenticated;

-- 新案件：每個 IP 每小時 10 件；全站 10 分鐘 300 件
create or replace function public.limit_cases() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.rate_check('case', 10, interval '1 hour', 300, interval '10 minutes');
  return new;
end $$;

-- 目擊：每個 IP 10 分鐘 20 筆；同一案件 10 分鐘 60 筆；全站 10 分鐘 1000 筆
create or replace function public.limit_sightings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
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
  return new;
end $$;

-- 拾獲／目擊／受傷通報：每個 IP 每小時 20 筆；全站 10 分鐘 400 筆
create or replace function public.create_found(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_token text := encode(gen_random_bytes(18), 'hex');
  v_id uuid;
  v_kind text := coalesce(nullif(p->>'kind',''),'seen');
begin
  if coalesce(p->>'city','') = '' or p->>'seen_at' is null then raise exception '缺少必填欄位'; end if;
  if v_kind not in ('found','seen','injured') then v_kind := 'seen'; end if;
  perform public.rate_check('found', 20, interval '1 hour', 400, interval '10 minutes');
  insert into public.found_reports (
    species, kind, seen_at, city, district, place_text, lat, lng, breed, sex, size, colour, features,
    collar_desc, current_place, photos, reporter_name, reporter_phone, phone_public, reporter_email,
    reporter_line, notes, injury, edit_token
  ) values (
    case when p->>'species' = 'cat' then 'cat' else 'dog' end,
    v_kind, (p->>'seen_at')::timestamptz, p->>'city', p->>'district',
    p->>'place_text', (p->>'lat')::double precision, (p->>'lng')::double precision, p->>'breed',
    nullif(p->>'sex',''), nullif(p->>'size',''), p->>'colour', p->>'features', p->>'collar_desc',
    p->>'current_place',
    coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'photos','[]'::jsonb)) x), '{}'),
    p->>'reporter_name', p->>'reporter_phone', coalesce((p->>'phone_public')::boolean,true),
    p->>'reporter_email', p->>'reporter_line', p->>'notes', nullif(p->>'injury',''), encode(digest(v_token,'sha256'),'hex')
  ) returning id into v_id;
  return jsonb_build_object('id', v_id, 'token', v_token);
end $$;
grant execute on function public.create_found(jsonb) to anon, authenticated;

-- 2 ---------------------------------------------------------------------------
alter table public.cases add column if not exists email_verified boolean not null default false;
alter table public.cases add column if not exists email_verify_hash text;
alter table public.cases add column if not exists email_verify_sent_at timestamptz;
-- 這次之前登記的案件視為已確認（避免舊飼主突然收不到通知）
do $$ begin
  if not exists (select 1 from public.cases where email_verified) then
    update public.cases set email_verified = true where contact_email is not null;
  end if;
end $$;
revoke update (email_verified, email_verify_hash, email_verify_sent_at) on public.cases from anon, authenticated;

-- 信箱有變動：重新需要確認；如果是登入會員填自己帳號的信箱，直接算已確認
create or replace function public.case_email_verify() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare v_mail text;
begin
  if tg_op = 'INSERT' or new.contact_email is distinct from old.contact_email then
    new.email_verified := false;
    new.email_verify_hash := null;
    new.email_verify_sent_at := null;
    if new.contact_email is not null and auth.uid() is not null
       and (new.owner_id = auth.uid() or tg_op = 'INSERT') then
      select email into v_mail from auth.users where id = auth.uid();
      if v_mail is not null and lower(btrim(v_mail)) = lower(btrim(new.contact_email)) then
        new.email_verified := true;
      end if;
    end if;
  end if;
  -- 其他欄位的更新不會動到確認狀態（anon／會員無權直接改 cases，只能透過 RPC，而 RPC 不會改這三欄）
  return new;
end $$;
drop trigger if exists cases_zz_email_verify on public.cases;
create trigger cases_zz_email_verify before insert or update on public.cases
  for each row execute function public.case_email_verify();

-- 點確認信裡的連結
create or replace function public.verify_case_email(p_id uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.cases;
begin
  perform public.rate_check('verify', 30, interval '10 minutes', 2000, interval '10 minutes');
  select * into r from public.cases where id = p_id;
  if r.id is null then return jsonb_build_object('ok', false); end if;
  if r.email_verified then return jsonb_build_object('ok', true, 'name', r.name, 'already', true); end if;
  if p_key is null or r.email_verify_hash is null or r.email_verify_hash <> encode(digest(p_key,'sha256'),'hex')
     or r.email_verify_sent_at < now() - interval '7 days' then
    return jsonb_build_object('ok', false);
  end if;
  update public.cases set email_verified = true, email_verify_hash = null where id = p_id;
  return jsonb_build_object('ok', true, 'name', r.name);
end $$;
grant execute on function public.verify_case_email(uuid, text) to anon, authenticated;

-- 3 ---------------------------------------------------------------------------
alter table public.reports add column if not exists reporter_ip text;
create or replace function public.report_content(p_type text, p_id uuid, p_reason text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_ip text := public.client_ip();
begin
  if p_type not in ('case','found','sighting') then raise exception '類型錯誤'; end if;
  if p_type = 'case' and not exists (select 1 from public.cases where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'found' and not exists (select 1 from public.found_reports where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'sighting' and not exists (select 1 from public.sightings where id = p_id) then raise exception '找不到內容'; end if;
  -- 同一個人（會員或同一 IP）對同一內容只記一次
  if exists (select 1 from public.reports where target_id = p_id and not resolved
             and ((auth.uid() is not null and reporter_id = auth.uid()) or (v_ip <> 'unknown' and reporter_ip = v_ip))) then
    return;
  end if;
  perform public.rate_check('report', 20, interval '10 minutes', 500, interval '10 minutes');
  insert into public.reports (target_type, target_id, reason, note, reporter_id, reporter_ip)
  values (p_type, p_id, left(p_reason, 50), left(p_note, 500), auth.uid(), v_ip);
end $$;
grant execute on function public.report_content(text, uuid, text, text) to anon, authenticated;

-- 4 ---------------------------------------------------------------------------
create or replace function public.report_shelter_matches(p_case uuid, p_rows jsonb, p_token text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_n integer := 0;
  r jsonb;
  v_trusted boolean := public.can_manage_case(p_case, p_token);
  v_name text;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 30 then
    raise exception '資料格式錯誤';
  end if;
  if not exists (select 1 from public.cases where id = p_case and status = 'searching' and not hidden) then
    return 0;
  end if;
  -- 非飼主送來的：每個案件最多累積 60 筆，避免被灌假資料
  if not v_trusted and (select count(*) from public.shelter_matches where case_id = p_case) >= 60 then
    return 0;
  end if;
  if not v_trusted then perform public.rate_check('shelter', 60, interval '10 minutes', 3000, interval '10 minutes'); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_name := left(r->>'shelter_name', 60);
    if not v_trusted and (v_name ~ '[0-9０-９]' or v_name ~* '(http|line|www|@)') then v_name := null; end if;
    insert into public.shelter_matches (
      case_id, animal_id, animal_subid, shelter_name, shelter_tel, shelter_address, found_place,
      colour, bodytype, sex, age, variety, photo_url, open_date, score
    ) values (
      p_case,
      left(r->>'animal_id', 30),
      left(r->>'animal_subid', 40),
      v_name,
      case when v_trusted then left(r->>'shelter_tel', 30) end,
      case when v_trusted then left(r->>'shelter_address', 120) end,
      case when v_trusted then left(r->>'found_place', 120) end,
      left(r->>'colour', 20),
      left(r->>'bodytype', 10),
      left(r->>'sex', 10),
      left(r->>'age', 10),
      left(r->>'variety', 30),
      case when r->>'photo_url' like 'https://www.pet.gov.tw/%' then left(r->>'photo_url', 200) else null end,
      case when r->>'open_date' ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'open_date')::date else null end,
      greatest(0, least(100, coalesce((r->>'score')::integer, 0)))
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

drop policy if exists "public read matches" on public.shelter_matches;
create policy "public read matches" on public.shelter_matches for select to anon, authenticated
  using (exists (select 1 from public.cases c where c.id = case_id and not c.hidden));

-- 5 ---------------------------------------------------------------------------
create or replace function public.set_sighting_status(p_case uuid, p_sighting uuid, p_token text, p_status text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_status not in ('pending','confirmed','rejected') then raise exception '狀態錯誤'; end if;
  if not public.can_manage_case(p_case, p_token) then raise exception '管理連結無效'; end if;
  if exists (select 1 from public.sightings where id = p_sighting and status_before_hide is not null) then
    raise exception '這則目擊已被網站管理員隱藏，無法更改';
  end if;
  update public.sightings set status = p_status where id = p_sighting and case_id = p_case;
end $$;

-- 6 ---------------------------------------------------------------------------
alter table public.cases drop constraint if exists cases_len2;
alter table public.cases add constraint cases_len2 check (
  char_length(coalesce(contact_name,''))  <= 50 and
  char_length(coalesce(contact_phone,'')) <= 30 and
  char_length(coalesce(contact_email,'')) <= 120 and
  char_length(coalesce(contact_line,''))  <= 60 and
  char_length(coalesce(age_text,''))      <= 30 and
  char_length(coalesce(chip_last4,''))    <= 4 and
  char_length(coalesce(lost_district,'')) <= 20 and
  char_length(coalesce(lost_city,''))     <= 10 and
  (found_method is null or found_method in ('','網友目擊回報','自己在附近找到','收容所／動保處通報','動物醫院掃晶片','FB／LINE 社團貼文','實體海報','鄰居／里長協助','外送員／郵差等看到','自己回家','其他'))
) not valid;
alter table public.found_reports drop constraint if exists fr_len2;
alter table public.found_reports add constraint fr_len2 check (
  char_length(coalesce(reporter_phone,'')) <= 30 and
  char_length(coalesce(reporter_email,'')) <= 120 and
  char_length(coalesce(reporter_line,''))  <= 60 and
  char_length(coalesce(district,''))       <= 20 and
  char_length(coalesce(city,''))           <= 10 and
  char_length(coalesce(injury,''))         <= 200
) not valid;

-- 7 ---------------------------------------------------------------------------
drop policy if exists "public read photos" on storage.objects;
drop policy if exists "own photos read" on storage.objects;
create policy "own photos read" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and owner_id = (select auth.uid())::text);

select 'WangMiao migration v1.17 installed' as result;

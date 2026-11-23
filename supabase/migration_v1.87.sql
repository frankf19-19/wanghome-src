-- 汪喵回家 migration v1.87 — 民眾送養區（第一期）
--   送養人刊登 → 想領養的人填申請問卷 → 送養人看申請、決定「婉拒／再聊聊／同意見面」
--   同意見面之後，雙方才看得到彼此的電話；之前用站內訊息聊。
--   線上認養切結書（雙方都勾選同意）→ 送養人按「完成送養」。
--   禁止買賣：只能收實際花費（附收據），上限 5000 元；文字擋買賣、配種字眼。
--   可重複執行。

-- ---------------------------------------------------------------- 共用檢查
create or replace function public.rehome_text_ok(t text) returns boolean
language sql immutable as $$
  select coalesce(t, '') !~* '(販賣|出售|販售|代售|售價|價格|價錢|配種|借種|種公|種母|繁殖|出清|轉讓費|賣場|私訊報價)'
$$;

create or replace function public.rehome_photos_ok(a text[]) returns boolean
language sql immutable as $$
  select coalesce(array_length(a, 1), 0) between 1 and 6
     and not exists (select 1 from unnest(a) x
                     where x !~ '^https://nopyhfpaykkiieudvoko\.supabase\.co/storage/v1/object/public/photos/cases/[^\s''"<>]+$')
$$;

create or replace function public.rehome_phone_ok(t text) returns boolean
language sql immutable as $$
  select coalesce(t, '') ~ '^[0-9０-９+＋\-－\s\(\)#＃]{8,30}$'
$$;

-- ---------------------------------------------------------------- 送養刊登
create table if not exists public.rehomes (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  species       text not null check (species in ('dog','cat')),
  name          text not null check (char_length(name) between 1 and 30),
  sex           text not null default 'unknown' check (sex in ('male','female','unknown')),
  age_text      text check (char_length(coalesce(age_text,'')) <= 20),
  breed         text check (char_length(coalesce(breed,'')) <= 30),
  size          text check (size is null or size in ('small','medium','large')),
  neutered      text not null default 'unknown' check (neutered in ('yes','no','unknown')),
  vaccine       text not null default 'unknown' check (vaccine in ('yes','partial','no','unknown')),
  chip          text not null default 'unknown' check (chip in ('yes','no','unknown')),
  temperament   text check (char_length(coalesce(temperament,'')) <= 300),
  health        text check (char_length(coalesce(health,'')) <= 300),
  story         text check (char_length(coalesce(story,'')) <= 1000),
  photos        text[] not null check (public.rehome_photos_ok(photos)),
  city          text not null check (char_length(city) <= 10),
  district      text check (char_length(coalesce(district,'')) <= 10),
  fee           integer not null default 0 check (fee between 0 and 5000),
  fee_note      text check (char_length(coalesce(fee_note,'')) <= 100),
  req_visit     boolean not null default false,
  req_contract  boolean not null default true,
  req_followup  boolean not null default true,
  req_cities    text[] not null default '{}' check (coalesce(array_length(req_cities,1),0) <= 22),
  req_note      text check (char_length(coalesce(req_note,'')) <= 300),
  contact_name  text not null check (char_length(contact_name) between 1 and 20),
  contact_phone text not null check (public.rehome_phone_ok(contact_phone)),
  status        text not null default 'open' check (status in ('open','paused','adopted','closed')),
  adopter_app   uuid,
  hidden        boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  adopted_at    timestamptz
);
create index if not exists rehomes_list_idx on public.rehomes(status, created_at desc) where not hidden;
create index if not exists rehomes_owner_idx on public.rehomes(owner_id);
alter table public.rehomes enable row level security;
drop policy if exists "rehomes own" on public.rehomes;
create policy "rehomes own" on public.rehomes for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create or replace function public.rehomes_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare sys boolean := coalesce(current_setting('wh.rehome_sys', true), '') = '1';
begin
  if auth.uid() is not null and not sys then
    if tg_op = 'INSERT' then
      new.hidden := false; new.adopter_app := null; new.adopted_at := null;
      if new.status not in ('open','paused') then new.status := 'open'; end if;
      if (select count(*) from public.rehomes where owner_id = new.owner_id and created_at > now() - interval '1 day') >= 5 then
        raise exception '一天最多刊登 5 隻';
      end if;
      if not exists (select 1 from public.profiles where id = new.owner_id and username is not null) then
        raise exception '刊登送養前，請先設定會員 ID';
      end if;
    else
      new.hidden := old.hidden; new.owner_id := old.owner_id; new.adopter_app := old.adopter_app;
      new.adopted_at := old.adopted_at; new.created_at := old.created_at;
      -- 已完成送養的不能改回刊登中；要改狀態只能在 open / paused / closed 之間
      if old.status = 'adopted' then new.status := 'adopted';
      elsif new.status = 'adopted' then new.status := old.status; end if;
    end if;
  end if;
  if not public.rehome_text_ok(concat_ws(' ', new.name, new.breed, new.temperament, new.health, new.story, new.req_note, new.fee_note)) then
    raise exception '送養區禁止買賣、配種相關內容';
  end if;
  if new.fee > 0 and coalesce(btrim(new.fee_note), '') = '' then
    raise exception '有收費用的話，請寫清楚是哪些實際花費（例如疫苗、結紮），交接時要附收據';
  end if;
  if exists (select 1 from public.bans b where b.user_id = new.owner_id and (b.expires_at is null or b.expires_at > now())) then
    raise exception '帳號已停權';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists rehomes_guard on public.rehomes;
create trigger rehomes_guard before insert or update on public.rehomes for each row execute function public.rehomes_guard();

-- ---------------------------------------------------------------- 領養申請
create table if not exists public.rehome_apps (
  id                 uuid primary key default gen_random_uuid(),
  rehome_id          uuid not null references public.rehomes(id) on delete cascade,
  applicant_id       uuid not null references auth.users(id) on delete cascade,
  answers            jsonb not null default '{}'::jsonb,
  intro              text check (char_length(coalesce(intro,'')) <= 1000),
  contact_name       text not null check (char_length(contact_name) between 1 and 20),
  contact_phone      text not null check (public.rehome_phone_ok(contact_phone)),
  status             text not null default 'pending' check (status in ('pending','talking','meet','declined','withdrawn','adopted')),
  id_checked         boolean not null default false,
  owner_agree_at     timestamptz,
  applicant_agree_at timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (rehome_id, applicant_id)
);
create index if not exists rehome_apps_rehome_idx on public.rehome_apps(rehome_id, status);
create index if not exists rehome_apps_applicant_idx on public.rehome_apps(applicant_id, created_at desc);
alter table public.rehome_apps enable row level security;
revoke all on public.rehome_apps from anon, authenticated;   -- 只能透過下面的函式讀寫

alter table public.rehomes drop constraint if exists rehomes_adopter_app_fkey;
alter table public.rehomes add constraint rehomes_adopter_app_fkey foreign key (adopter_app) references public.rehome_apps(id) on delete set null;

-- 公開列表（不含電話）
create or replace view public.rehomes_public with (security_invoker = false) as
  select r.id, r.owner_id, r.species, r.name, r.sex, r.age_text, r.breed, r.size, r.neutered, r.vaccine, r.chip,
         r.temperament, r.health, r.story, r.photos, r.city, r.district, r.fee, r.fee_note,
         r.req_visit, r.req_contract, r.req_followup, r.req_cities, r.req_note, r.contact_name,
         r.status, r.created_at, r.updated_at, r.adopted_at,
         p.username, p.avatar_url, p.created_at as owner_joined,
         (select count(*) from public.rehome_apps a where a.rehome_id = r.id and a.status <> 'withdrawn')::int as app_count
    from public.rehomes r join public.profiles p on p.id = r.owner_id
   where not r.hidden and r.status <> 'closed' and p.username is not null
     and not exists (select 1 from public.bans b where b.user_id = r.owner_id and (b.expires_at is null or b.expires_at > now()));
grant select on public.rehomes_public to anon, authenticated;

-- 送出申請（同一隻只能申請一次；撤回後可以重新申請）
create or replace function public.rehome_apply(p_rehome uuid, p_answers jsonb, p_intro text, p_name text, p_phone text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.rehomes; aid uuid; st text; c text;
begin
  if me is null then raise exception '請先登入'; end if;
  if public.is_banned() then raise exception '帳號暫停使用'; end if;
  if not exists (select 1 from public.profiles where id = me and username is not null) then raise exception '申請領養前，請先設定會員 ID'; end if;
  select * into r from public.rehomes where id = p_rehome and not hidden;
  if r.id is null then raise exception '找不到這則送養'; end if;
  if r.owner_id = me then raise exception '這是你刊登的'; end if;
  if r.status <> 'open' then raise exception '這隻目前沒有開放申請'; end if;
  if public.chat_blocked(me, r.owner_id) then raise exception '無法申請這則送養'; end if;
  if jsonb_typeof(coalesce(p_answers, '{}'::jsonb)) <> 'object' or length(p_answers::text) > 6000 then raise exception '問卷格式錯誤'; end if;
  if coalesce(p_answers->>'adult', '') <> 'yes' then raise exception '領養人需要年滿 20 歲'; end if;
  c := p_answers->>'city';
  if coalesce(array_length(r.req_cities, 1), 0) > 0 and (c is null or not (c = any(r.req_cities))) then
    raise exception '送養人只送養到：%', array_to_string(r.req_cities, '、');
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 20 then raise exception '請填怎麼稱呼你'; end if;
  if not public.rehome_phone_ok(p_phone) then raise exception '請填正確的手機號碼'; end if;
  if not public.rehome_text_ok(p_intro) then raise exception '內容不符合送養區規定'; end if;
  select id, status into aid, st from public.rehome_apps where rehome_id = p_rehome and applicant_id = me;
  if aid is not null and st <> 'withdrawn' then raise exception '你已經申請過這隻了'; end if;
  if (select count(*) from public.rehome_apps where applicant_id = me and created_at > now() - interval '1 day') >= 5 then
    raise exception '一天最多申請 5 隻，請先跟已申請的送養人聊聊';
  end if;
  if aid is not null then
    update public.rehome_apps set answers = p_answers, intro = nullif(btrim(p_intro), ''), contact_name = btrim(p_name),
           contact_phone = btrim(p_phone), status = 'pending', id_checked = false, owner_agree_at = null, applicant_agree_at = null,
           created_at = now(), updated_at = now()
     where id = aid;
  else
    insert into public.rehome_apps(rehome_id, applicant_id, answers, intro, contact_name, contact_phone)
      values (p_rehome, me, p_answers, nullif(btrim(p_intro), ''), btrim(p_name), btrim(p_phone)) returning id into aid;
  end if;
  return aid;
end $$;

-- 改申請狀態：送養人 → talking／meet／declined；申請人 → withdrawn
create or replace function public.rehome_app_set(p_app uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); a public.rehome_apps; r public.rehomes;
begin
  if me is null then raise exception '請先登入'; end if;
  select * into a from public.rehome_apps where id = p_app;
  if a.id is null then raise exception '找不到這份申請'; end if;
  select * into r from public.rehomes where id = a.rehome_id;
  if a.status in ('declined','withdrawn','adopted') then raise exception '這份申請已經結束了'; end if;
  if me = r.owner_id then
    if p_status not in ('talking','meet','declined') then raise exception '格式錯誤'; end if;
    if r.status = 'adopted' and p_status <> 'declined' then raise exception '這隻已經完成送養了'; end if;
    if p_status = 'talking' and a.status <> 'pending' then raise exception '已經在聊了'; end if;
  elsif me = a.applicant_id then
    if p_status <> 'withdrawn' then raise exception '格式錯誤'; end if;
  else raise exception '找不到這份申請'; end if;
  update public.rehome_apps set status = p_status, updated_at = now(),
         owner_agree_at = case when p_status = 'meet' then owner_agree_at end,
         applicant_agree_at = case when p_status = 'meet' then applicant_agree_at end
   where id = p_app;
end $$;

-- 認養切結書：雙方各自勾選同意（送養人另外確認「已核對證件」）
create or replace function public.rehome_agree(p_app uuid, p_id_checked boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); a public.rehome_apps; r public.rehomes;
begin
  select * into a from public.rehome_apps where id = p_app;
  if a.id is null then raise exception '找不到這份申請'; end if;
  select * into r from public.rehomes where id = a.rehome_id;
  if a.status <> 'meet' then raise exception '送養人同意見面之後，才能簽切結書'; end if;
  if me = r.owner_id then
    if not coalesce(p_id_checked, false) then raise exception '請先當面核對領養人的身分證件'; end if;
    update public.rehome_apps set owner_agree_at = now(), id_checked = true, updated_at = now() where id = p_app;
  elsif me = a.applicant_id then
    update public.rehome_apps set applicant_agree_at = now(), updated_at = now() where id = p_app;
  else raise exception '找不到這份申請'; end if;
end $$;

-- 完成送養：只有送養人可以按；要求切結書的話，雙方都要先同意
create or replace function public.rehome_complete(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); a public.rehome_apps; r public.rehomes;
begin
  select * into a from public.rehome_apps where id = p_app;
  if a.id is null then raise exception '找不到這份申請'; end if;
  select * into r from public.rehomes where id = a.rehome_id;
  if me is null or me <> r.owner_id then raise exception '只有送養人可以完成送養'; end if;
  if a.status <> 'meet' then raise exception '要先同意見面，才能完成送養'; end if;
  if r.status = 'adopted' then raise exception '這隻已經完成送養了'; end if;
  if r.req_contract and (a.owner_agree_at is null or a.applicant_agree_at is null) then
    raise exception '雙方都簽好切結書之後，才能完成送養';
  end if;
  perform set_config('wh.rehome_sys', '1', true);
  update public.rehome_apps set status = 'adopted', updated_at = now() where id = p_app;
  update public.rehome_apps set status = 'declined', updated_at = now()
   where rehome_id = r.id and id <> p_app and status in ('pending','talking','meet');
  update public.rehomes set status = 'adopted', adopter_app = p_app, adopted_at = now() where id = r.id;
  perform set_config('wh.rehome_sys', '', true);
end $$;

-- 送養人看申請：問卷、會員資料、可疑訊號；同意見面之後才看得到電話
create or replace function public.rehome_apps_for(p_rehome uuid)
returns table(id uuid, applicant_id uuid, username text, avatar_url text, joined timestamptz,
              answers jsonb, intro text, contact_name text, contact_phone text, status text,
              id_checked boolean, owner_agree_at timestamptz, applicant_agree_at timestamptz,
              created_at timestamptz, updated_at timestamptz, apps_7d integer, reports integer, has_pets boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.rehomes r where r.id = p_rehome and r.owner_id = auth.uid()) then
    raise exception '只有送養人看得到申請';
  end if;
  return query
  select a.id, a.applicant_id, p.username, p.avatar_url, p.created_at,
         a.answers, a.intro, a.contact_name,
         case when a.status in ('meet','adopted') then a.contact_phone end,
         a.status, a.id_checked, a.owner_agree_at, a.applicant_agree_at, a.created_at, a.updated_at,
         (select count(*) from public.rehome_apps x where x.applicant_id = a.applicant_id and x.created_at > now() - interval '7 days')::int,
         (select count(*) from public.reports rp where rp.target_type = 'user' and rp.target_id = a.applicant_id)::int,
         exists (select 1 from public.pets pt where pt.owner_id = a.applicant_id)
    from public.rehome_apps a join public.profiles p on p.id = a.applicant_id
   where a.rehome_id = p_rehome
   order by case a.status when 'meet' then 0 when 'talking' then 1 when 'pending' then 2 when 'adopted' then 3 else 4 end, a.created_at desc;
end $$;

-- 一份申請的詳細（送養人或申請人都可以看）；同意見面之後才互相看得到電話
create or replace function public.rehome_app_get(p_app uuid)
returns table(id uuid, rehome_id uuid, my_role text, status text, answers jsonb, intro text,
              applicant_name text, applicant_phone text, applicant_username text,
              owner_name text, owner_phone text, owner_username text,
              pet_name text, pet_species text, pet_sex text, pet_photo text, pet_chip text, pet_neutered text,
              req_contract boolean, req_visit boolean, req_followup boolean, fee integer, fee_note text,
              id_checked boolean, owner_agree_at timestamptz, applicant_agree_at timestamptz,
              created_at timestamptz, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.id, a.rehome_id, case when r.owner_id = auth.uid() then 'owner' else 'applicant' end, a.status, a.answers, a.intro,
         a.contact_name, case when a.status in ('meet','adopted') then a.contact_phone end, pa.username,
         r.contact_name, case when a.status in ('meet','adopted') then r.contact_phone end, po.username,
         r.name, r.species, r.sex, r.photos[1], r.chip, r.neutered,
         r.req_contract, r.req_visit, r.req_followup, r.fee, r.fee_note,
         a.id_checked, a.owner_agree_at, a.applicant_agree_at, a.created_at, a.updated_at
    from public.rehome_apps a
    join public.rehomes r on r.id = a.rehome_id
    left join public.profiles pa on pa.id = a.applicant_id
    left join public.profiles po on po.id = r.owner_id
   where a.id = p_app and (r.owner_id = auth.uid() or a.applicant_id = auth.uid());
$$;

-- 我送出的申請
create or replace function public.rehome_my_apps()
returns table(id uuid, rehome_id uuid, status text, created_at timestamptz, updated_at timestamptz,
              pet_name text, pet_species text, pet_photo text, city text, district text, owner_username text, rehome_status text)
language sql stable security definer set search_path = public as $$
  select a.id, a.rehome_id, a.status, a.created_at, a.updated_at, r.name, r.species, r.photos[1], r.city, r.district, p.username, r.status
    from public.rehome_apps a join public.rehomes r on r.id = a.rehome_id left join public.profiles p on p.id = r.owner_id
   where a.applicant_id = auth.uid()
   order by a.updated_at desc limit 100;
$$;

-- 通知：送養人收到新申請；申請人的申請狀態有變
create or replace function public.rehome_inbox()
returns table(app_id uuid, rehome_id uuid, pet_name text, pet_photo text, role text, status text, who text, at timestamptz)
language sql stable security definer set search_path = public as $$
  (select a.id, r.id, r.name, r.photos[1], 'owner', a.status, p.username, a.created_at
     from public.rehome_apps a join public.rehomes r on r.id = a.rehome_id left join public.profiles p on p.id = a.applicant_id
    where r.owner_id = auth.uid() and a.status = 'pending' and a.created_at > now() - interval '14 days'
    order by a.created_at desc limit 20)
  union all
  (select a.id, r.id, r.name, r.photos[1], 'applicant', a.status, p.username, a.updated_at
     from public.rehome_apps a join public.rehomes r on r.id = a.rehome_id left join public.profiles p on p.id = r.owner_id
    where a.applicant_id = auth.uid() and a.status in ('talking','meet','declined','adopted') and a.updated_at > now() - interval '14 days'
    order by a.updated_at desc limit 20);
$$;

revoke all on function public.rehome_apply(uuid, jsonb, text, text, text), public.rehome_app_set(uuid, text),
  public.rehome_agree(uuid, boolean), public.rehome_complete(uuid), public.rehome_apps_for(uuid),
  public.rehome_app_get(uuid), public.rehome_my_apps(), public.rehome_inbox() from public, anon;
grant execute on function public.rehome_apply(uuid, jsonb, text, text, text), public.rehome_app_set(uuid, text),
  public.rehome_agree(uuid, boolean), public.rehome_complete(uuid), public.rehome_apps_for(uuid),
  public.rehome_app_get(uuid), public.rehome_my_apps(), public.rehome_inbox() to authenticated;

-- ---------------------------------------------------------------- 站內訊息：送養人和申請人聊天
alter table public.chats add column if not exists rehome_app_id uuid references public.rehome_apps(id) on delete set null;
alter table public.chats drop constraint if exists chats_kind_check;
alter table public.chats add constraint chats_kind_check check (kind in ('case','found','dm','rehome'));

create or replace function public.chat_open(p_kind text, p_ref uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); other uuid; cid uuid; ok boolean; myrole text := 'helper'; orole text := 'owner';
        ra public.rehome_apps; rr public.rehomes;
begin
  if me is null then raise exception '請先登入'; end if;
  if public.is_banned() then raise exception '帳號暫停使用'; end if;
  if p_kind = 'case' then
    select owner_id into other from public.cases where id = p_ref and not coalesce(hidden, false);
    if other is null then raise exception '這個案件沒有綁定會員，請用頁面上的電話或回報目擊聯絡'; end if;
  elsif p_kind = 'found' then
    select owner_id into other from public.found_reports where id = p_ref and not coalesce(hidden, false);
    if other is null then raise exception '這則通報沒有綁定會員，請用頁面上的聯絡方式'; end if;
  elsif p_kind = 'dm' then
    other := p_ref;
    select dm_open into ok from public.profiles where id = other and username is not null;
    if ok is null then raise exception '找不到這位會員'; end if;
  elsif p_kind = 'rehome' then
    select * into ra from public.rehome_apps where id = p_ref;
    if ra.id is null then raise exception '找不到這份申請'; end if;
    select * into rr from public.rehomes where id = ra.rehome_id;
    if me = rr.owner_id then other := ra.applicant_id; myrole := 'owner'; orole := 'helper';
    elsif me = ra.applicant_id then other := rr.owner_id;
    else raise exception '找不到這份申請'; end if;
  else raise exception '格式錯誤'; end if;
  if other = me then raise exception '這是你自己的'; end if;
  if public.chat_blocked(me, other) then raise exception '無法傳訊息給這位會員'; end if;
  select c.id into cid from public.chats c
    join public.chat_members a on a.chat_id = c.id and a.user_id = me
    join public.chat_members b on b.chat_id = c.id and b.user_id = other
   where c.kind = p_kind
     and (p_kind <> 'case' or c.case_id = p_ref)
     and (p_kind <> 'found' or c.found_id = p_ref)
     and (p_kind <> 'rehome' or c.rehome_app_id = p_ref)
   order by c.created_at limit 1;
  if cid is not null then
    update public.chat_members set hidden = false where chat_id = cid and user_id = me;
    return cid;
  end if;
  if p_kind = 'dm' and not ok and not public.are_friends(me, other) then raise exception '這位會員目前不接受私訊'; end if;
  if p_kind = 'case' and not exists (select 1 from public.cases where id = p_ref and status = 'searching') then raise exception '這個案件已經結案了'; end if;
  if p_kind = 'found' and not exists (select 1 from public.found_reports where id = p_ref and status = 'open') then raise exception '這則通報已經結案了'; end if;
  if p_kind = 'rehome' and ra.status not in ('talking','meet','adopted') then raise exception '送養人回覆「再聊聊」之後，才能傳訊息'; end if;
  if (select count(*) from public.chats where created_by = me and created_at > now() - interval '1 day') >= 20 then
    raise exception '今天開的新對話太多了，明天再試';
  end if;
  perform pg_advisory_xact_lock(hashtext(least(me::text, other::text) || greatest(me::text, other::text) || p_kind || coalesce(p_ref::text, '')));
  select c.id into cid from public.chats c
    join public.chat_members a on a.chat_id = c.id and a.user_id = me
    join public.chat_members b on b.chat_id = c.id and b.user_id = other
   where c.kind = p_kind and (p_kind <> 'case' or c.case_id = p_ref) and (p_kind <> 'found' or c.found_id = p_ref)
     and (p_kind <> 'rehome' or c.rehome_app_id = p_ref) limit 1;
  if cid is not null then return cid; end if;
  insert into public.chats(kind, case_id, found_id, rehome_app_id, created_by)
    values (p_kind, case when p_kind = 'case' then p_ref end, case when p_kind = 'found' then p_ref end,
            case when p_kind = 'rehome' then p_ref end, me)
    returning id into cid;
  insert into public.chat_members(chat_id, user_id, role, last_read_at) values
    (cid, me, case when p_kind = 'dm' then 'member' else myrole end, now()),
    (cid, other, case when p_kind = 'dm' then 'member' else orole end, now() - interval '1 second');
  return cid;
end $$;

create or replace function public.chat_list() returns table(
  chat_id uuid, kind text, case_id uuid, found_id uuid, title text, photo text,
  other_id uuid, other_name text, other_avatar text, my_role text,
  last_at timestamptz, last_text text, last_sender uuid, unread integer, muted boolean, pinned boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.kind, c.case_id, c.found_id,
         case when c.kind = 'case' then cs.name
              when c.kind = 'found' then case f.kind when 'injured' then '受傷通報' when 'found' then '撿到通報' else '目擊通報' end
              when c.kind = 'rehome' then rh.name
              else null end,
         case when c.kind = 'case' then cs.photos[1] when c.kind = 'found' then f.photos[1] when c.kind = 'rehome' then rh.photos[1] end,
         o.user_id, p.username, p.avatar_url, m.role,
         c.last_at, c.last_text, c.last_sender,
         (select count(*)::int from public.chat_messages x where x.chat_id = c.id and x.sender_id <> auth.uid() and x.created_at > m.last_read_at),
         m.muted, m.pinned_at is not null
    from public.chat_members m
    join public.chats c on c.id = m.chat_id
    left join public.chat_members o on o.chat_id = c.id and o.user_id <> m.user_id
    left join public.profiles p on p.id = o.user_id
    left join public.cases cs on cs.id = c.case_id
    left join public.found_reports f on f.id = c.found_id
    left join public.rehome_apps ra on ra.id = c.rehome_app_id
    left join public.rehomes rh on rh.id = ra.rehome_id
   where m.user_id = auth.uid() and not m.hidden
     and exists (select 1 from public.chat_messages x where x.chat_id = c.id)
   order by m.pinned_at desc nulls last, c.last_at desc
   limit 200;
$$;

-- ---------------------------------------------------------------- 檢舉、管理後台
alter table public.reports drop constraint if exists reports_target_type_check;
alter table public.reports add constraint reports_target_type_check check (target_type in ('case','found','sighting','message','user','comment','rehome'));

create or replace function public.report_content(p_type text, p_id uuid, p_reason text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_ip text := public.client_ip();
begin
  if p_type not in ('case','found','sighting','comment','rehome') then raise exception '類型錯誤'; end if;
  if p_type = 'case' and not exists (select 1 from public.cases where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'found' and not exists (select 1 from public.found_reports where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'sighting' and not exists (select 1 from public.sightings where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'comment' and not exists (select 1 from public.case_comments where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'rehome' and not exists (select 1 from public.rehomes where id = p_id) then raise exception '找不到內容'; end if;
  if exists (select 1 from public.reports where target_id = p_id and not resolved
             and ((auth.uid() is not null and reporter_id = auth.uid()) or (v_ip <> 'unknown' and reporter_ip = v_ip))) then
    return;
  end if;
  perform public.rate_check('report', 20, interval '10 minutes', 500, interval '10 minutes');
  insert into public.reports (target_type, target_id, reason, note, reporter_id, reporter_ip)
  values (p_type, p_id, left(p_reason, 50), left(p_note, 500), auth.uid(), v_ip);
  if p_type = 'comment' and (select count(*) from public.reports where target_id = p_id and not resolved) >= 3 then
    update public.case_comments set hidden = true where id = p_id;
  end if;
  -- 送養：3 個不同的人檢舉就先隱藏，等管理員看
  if p_type = 'rehome' and (select count(*) from public.reports where target_id = p_id and not resolved) >= 3 then
    perform set_config('wh.rehome_sys', '1', true);
    update public.rehomes set hidden = true where id = p_id;
    perform set_config('wh.rehome_sys', '', true);
  end if;
end $$;
grant execute on function public.report_content(text, uuid, text, text) to anon, authenticated;

create or replace function public.admin_reports(p_include_resolved boolean default false)
returns table(id uuid, created_at timestamptz, target_type text, target_id uuid, reason text, note text,
              resolved boolean, target_title text, target_hidden boolean, report_count bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return query
  select r.id, r.created_at, r.target_type, r.target_id, r.reason, r.note, r.resolved,
         coalesce(c.name, case when f.id is not null then coalesce(f.colour,'') || ' ' || f.city end,
                  case when s.id is not null then '目擊：' || coalesce(s.place_text,'') end,
                  case when pu.id is not null then '會員：' || coalesce(pu.username, '（未設定名稱）') end,
                  case when m.id is not null then '留言（' || coalesce(mc.name, '') || '）：' || left(m.body, 200) end,
                  case when rh.id is not null then '送養：' || rh.name || '（' || rh.city || '）' end) as target_title,
         coalesce(c.hidden, f.hidden, s.status = 'rejected', m.hidden, rh.hidden, false) as target_hidden,
         (select count(*) from public.reports r2 where r2.target_id = r.target_id and not r2.resolved) as report_count
  from public.reports r
  left join public.cases c on r.target_type = 'case' and c.id = r.target_id
  left join public.found_reports f on r.target_type = 'found' and f.id = r.target_id
  left join public.sightings s on r.target_type = 'sighting' and s.id = r.target_id
  left join public.profiles pu on r.target_type = 'user' and pu.id = r.target_id
  left join public.case_comments m on r.target_type = 'comment' and m.id = r.target_id
  left join public.cases mc on mc.id = m.case_id
  left join public.rehomes rh on r.target_type = 'rehome' and rh.id = r.target_id
  where p_include_resolved or not r.resolved
  order by r.resolved, r.created_at desc
  limit 300;
end $$;
revoke execute on function public.admin_reports(boolean) from anon, public;
grant execute on function public.admin_reports(boolean) to authenticated;

create or replace function public.admin_set_hidden(p_type text, p_id uuid, p_hidden boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then update public.cases set hidden = p_hidden where id = p_id;
  elsif p_type = 'found' then update public.found_reports set hidden = p_hidden where id = p_id;
  elsif p_type = 'comment' then update public.case_comments set hidden = p_hidden where id = p_id;
  elsif p_type = 'rehome' then
    perform set_config('wh.rehome_sys', '1', true);
    update public.rehomes set hidden = p_hidden where id = p_id;
    perform set_config('wh.rehome_sys', '', true);
  elsif p_type = 'sighting' then
    if p_hidden then
      update public.sightings set status_before_hide = case when status <> 'rejected' then status else status_before_hide end,
                                  status = 'rejected' where id = p_id;
    else
      update public.sightings set status = coalesce(nullif(status_before_hide, 'rejected'), 'pending'),
                                  status_before_hide = null where id = p_id;
    end if;
  else raise exception '類型錯誤'; end if;
end $$;
revoke execute on function public.admin_set_hidden(text, uuid, boolean) from anon, public;
grant execute on function public.admin_set_hidden(text, uuid, boolean) to authenticated;

create or replace function public.admin_ban(p_type text, p_id uuid, p_reason text default null, p_days int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_ip text;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then select owner_id, created_ip into v_uid, v_ip from public.cases where id = p_id;
  elsif p_type = 'found' then select owner_id, created_ip into v_uid, v_ip from public.found_reports where id = p_id;
  elsif p_type = 'sighting' then select reporter_id, created_ip into v_uid, v_ip from public.sightings where id = p_id;
  elsif p_type = 'comment' then select user_id, created_ip into v_uid, v_ip from public.case_comments where id = p_id;
  elsif p_type = 'rehome' then select owner_id, null::text into v_uid, v_ip from public.rehomes where id = p_id;
  else raise exception '類型錯誤'; end if;
  if not found then raise exception '找不到這則內容'; end if;
  if v_uid is null and (v_ip is null or v_ip = 'unknown') then
    perform public.admin_set_hidden(p_type, p_id, true);
    return jsonb_build_object('banned', false, 'hidden', true, 'note', '找不到發布者資料（超過 30 天的網路位址已清除），只隱藏內容');
  end if;
  insert into public.bans (user_id, ip, reason, expires_at)
  values (v_uid, nullif(v_ip, 'unknown'), left(p_reason, 200), case when p_days is not null then now() + make_interval(days => p_days) end);
  perform public.admin_set_hidden(p_type, p_id, true);
  update public.reports set resolved = true, resolved_at = now() where target_id = p_id and not resolved;
  return jsonb_build_object('banned', true, 'hidden', true, 'member', v_uid is not null);
end $$;
revoke execute on function public.admin_ban(text, uuid, text, int) from anon, public;
grant execute on function public.admin_ban(text, uuid, text, int) to authenticated;

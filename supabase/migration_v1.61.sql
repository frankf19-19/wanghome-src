-- 汪喵回家 migration v1.61 — 毛孩交朋友（第一版）：毛孩名片牆＋約散步
--   主角是毛孩：名片只放毛孩的照片、品種、個性、所在的「區」，不放飼主的聯絡方式和精確位置。
--   想聊天：到飼主的會員頁加好友／私訊（沿用原本的好友、私訊、檢舉、封鎖）。
--   禁止買賣、配種：資料庫直接擋。
--   可重複執行。

-- ---------------------------------------------------------------- 共用：檢查文字
create or replace function public.pals_text_ok(t text) returns boolean
language sql immutable as $$
  select coalesce(t, '') !~* '(販賣|出售|販售|代售|售價|價格|價錢|收費|配種|借種|種公|種母|繁殖|出清|轉讓費|\$\s*\d|\d+\s*(元|塊|萬))'
$$;

-- ---------------------------------------------------------------- 毛孩名片
create table if not exists public.pet_cards (
  pet_id     uuid primary key references public.pets(id) on delete cascade,
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  species    text not null check (species in ('dog','cat')),
  name       text not null check (char_length(name) between 1 and 30),
  breed      text check (char_length(coalesce(breed,'')) <= 30),
  sex        text check (sex in ('male','female','unknown')),
  size       text check (size in ('small','medium','large')),
  age_text   text check (char_length(coalesce(age_text,'')) <= 20),
  tags       text[] not null default '{}' check (coalesce(array_length(tags,1),0) <= 8),
  intro      text check (char_length(coalesce(intro,'')) <= 200),
  city       text not null check (char_length(city) <= 10),
  district   text check (char_length(coalesce(district,'')) <= 10),
  photo      text check (photo is null or photo ~ '^https://nopyhfpaykkiieudvoko\.supabase\.co/storage/v1/object/public/photos/cases/[^\s''"<>]+$'),
  hidden     boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists pet_cards_city_idx on public.pet_cards(city, species) where not hidden;
alter table public.pet_cards enable row level security;
drop policy if exists "pet_cards own" on public.pet_cards;
create policy "pet_cards own" on public.pet_cards for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid() and exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = auth.uid()));

create or replace function public.pet_cards_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    if tg_op = 'INSERT' then new.hidden := false; else new.hidden := old.hidden; new.owner_id := old.owner_id; end if;
  end if;
  if not public.pals_text_ok(new.intro) or not public.pals_text_ok(array_to_string(new.tags, ' ')) then
    raise exception '交朋友區禁止買賣、配種相關內容';
  end if;
  if exists (select 1 from public.bans b where b.user_id = new.owner_id and (b.expires_at is null or b.expires_at > now())) then
    raise exception '帳號已停權';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists pet_cards_guard on public.pet_cards;
create trigger pet_cards_guard before insert or update on public.pet_cards for each row execute function public.pet_cards_guard();

create or replace view public.pet_cards_public with (security_invoker = false) as
  select c.pet_id, c.owner_id, c.species, c.name, c.breed, c.sex, c.size, c.age_text, c.tags, c.intro,
         c.city, c.district, c.photo, c.updated_at, p.username, p.avatar_url
    from public.pet_cards c join public.profiles p on p.id = c.owner_id
   where not c.hidden and p.username is not null
     and not exists (select 1 from public.bans b where b.user_id = c.owner_id and (b.expires_at is null or b.expires_at > now()));
grant select on public.pet_cards_public to anon, authenticated;

-- ---------------------------------------------------------------- 約散步／約玩
create table if not exists public.pet_meets (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  species    text not null default 'dog' check (species in ('dog','cat','any')),
  title      text not null check (char_length(title) between 2 and 40),
  place      text not null check (char_length(place) between 2 and 60),
  city       text not null check (char_length(city) <= 10),
  district   text check (char_length(coalesce(district,'')) <= 10),
  starts_at  timestamptz not null,
  size_pref  text not null default 'any' check (size_pref in ('any','small','medium','large')),
  note       text check (char_length(coalesce(note,'')) <= 300),
  cap        integer not null default 8 check (cap between 2 and 30),
  hidden     boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists pet_meets_time_idx on public.pet_meets(starts_at) where not hidden;
alter table public.pet_meets enable row level security;
drop policy if exists "pet_meets own" on public.pet_meets;
create policy "pet_meets own" on public.pet_meets for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create or replace function public.pet_meets_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    if tg_op = 'INSERT' then
      new.hidden := false;
      if (select count(*) from public.pet_meets where owner_id = new.owner_id and created_at > now() - interval '1 day') >= 3 then
        raise exception '一天最多發 3 個活動';
      end if;
    else new.hidden := old.hidden; new.owner_id := old.owner_id; end if;
    if new.starts_at < now() or new.starts_at > now() + interval '30 days' then
      raise exception '時間請選 30 天內';
    end if;
  end if;
  if not public.pals_text_ok(new.title || ' ' || new.place || ' ' || coalesce(new.note, '')) then
    raise exception '交朋友區禁止買賣、配種相關內容';
  end if;
  -- 只能約公開地點：擋門牌、樓層
  if new.place ~ '[0-9０-９]+\s*(號|樓|F\b|f\b)' then
    raise exception '請填公園、寵物餐廳這類公開地點，不要填住家地址';
  end if;
  if exists (select 1 from public.bans b where b.user_id = new.owner_id and (b.expires_at is null or b.expires_at > now())) then
    raise exception '帳號已停權';
  end if;
  return new;
end $$;
drop trigger if exists pet_meets_guard on public.pet_meets;
create trigger pet_meets_guard before insert or update on public.pet_meets for each row execute function public.pet_meets_guard();

create table if not exists public.pet_meet_joins (
  meet_id    uuid not null references public.pet_meets(id) on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  pet_name   text check (char_length(coalesce(pet_name,'')) <= 30),
  created_at timestamptz not null default now(),
  primary key (meet_id, user_id)
);
alter table public.pet_meet_joins enable row level security;
drop policy if exists "pet_meet_joins own" on public.pet_meet_joins;
create policy "pet_meet_joins own" on public.pet_meet_joins for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.pet_meet_joins_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare m public.pet_meets;
begin
  select * into m from public.pet_meets where id = new.meet_id;
  if m.id is null or m.hidden or m.starts_at < now() then raise exception '這個活動已經結束或不存在'; end if;
  if m.owner_id = new.user_id then raise exception '你是發起人'; end if;
  if (select count(*) from public.pet_meet_joins where meet_id = new.meet_id) >= m.cap - 1 then raise exception '名額已滿'; end if;
  if not public.pals_text_ok(new.pet_name) then raise exception '名稱不符合規定'; end if;
  return new;
end $$;
drop trigger if exists pet_meet_joins_guard on public.pet_meet_joins;
create trigger pet_meet_joins_guard before insert on public.pet_meet_joins for each row execute function public.pet_meet_joins_guard();

create or replace view public.pet_meets_public with (security_invoker = false) as
  select m.id, m.owner_id, m.species, m.title, m.place, m.city, m.district, m.starts_at, m.size_pref, m.note, m.cap, m.created_at,
         p.username, p.avatar_url,
         (select count(*) from public.pet_meet_joins j where j.meet_id = m.id)::int as joined
    from public.pet_meets m join public.profiles p on p.id = m.owner_id
   where not m.hidden and m.starts_at > now() - interval '3 hours' and p.username is not null
     and not exists (select 1 from public.bans b where b.user_id = m.owner_id and (b.expires_at is null or b.expires_at > now()));
grant select on public.pet_meets_public to anon, authenticated;

-- 參加名單：只給登入的會員看（會員名稱＋帶哪隻毛孩）
create or replace view public.pet_meet_people with (security_invoker = false) as
  select j.meet_id, j.user_id, j.pet_name, j.created_at, p.username, p.avatar_url
    from public.pet_meet_joins j join public.profiles p on p.id = j.user_id
   where p.username is not null;
revoke all on public.pet_meet_people from anon;
grant select on public.pet_meet_people to authenticated;

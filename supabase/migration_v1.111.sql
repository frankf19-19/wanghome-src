-- 汪喵回家 migration v1.111 — QR 名牌：飼主替毛孩產生專屬 QR Code，撿到的人掃了就能聯絡飼主、回傳位置
--   公開頁：https://wangmiaotw.com/t/<代碼>（不用登入、不用裝 App）
--   可重複執行。

-- 1) 毛孩檔案：名牌設定
alter table public.pets add column if not exists tag_code  text;
alter table public.pets add column if not exists tag_on    boolean not null default false;
alter table public.pets add column if not exists tag_phone text;   -- 名牌頁上顯示的電話（飼主自己決定要不要放）
alter table public.pets add column if not exists tag_note  text;   -- 給撿到的人看的話
create unique index if not exists pets_tag_code_key on public.pets(tag_code) where tag_code is not null;
alter table public.pets drop constraint if exists pets_tag_len;
alter table public.pets add constraint pets_tag_len check (
  char_length(coalesce(tag_code, '')) <= 16 and char_length(coalesce(tag_phone, '')) <= 20 and char_length(coalesce(tag_note, '')) <= 200);

-- 2) 掃描紀錄：只有飼主看得到
create table if not exists public.pet_tag_scans (
  id         uuid primary key default gen_random_uuid(),
  pet_id     uuid not null references public.pets(id) on delete cascade,
  created_at timestamptz not null default now(),
  lat        double precision,
  lng        double precision,
  acc        real,
  msg        text,
  contact    text,
  pushed     boolean not null default false,
  constraint pet_tag_scans_len check (char_length(coalesce(msg, '')) <= 300 and char_length(coalesce(contact, '')) <= 60)
);
create index if not exists pet_tag_scans_pet_idx on public.pet_tag_scans(pet_id, created_at desc);
alter table public.pet_tag_scans enable row level security;
revoke all on public.pet_tag_scans from anon, authenticated;
grant select on public.pet_tag_scans to authenticated;
drop policy if exists "own tag scans" on public.pet_tag_scans;
create policy "own tag scans" on public.pet_tag_scans for select to authenticated
  using (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));

-- 3) 飼主：開關名牌、設定電話和留言；第一次開啟時產生代碼
create or replace function public.pet_tag_set(p_pet uuid, p_on boolean, p_phone text, p_note text)
returns text language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_code text; v_try int := 0;
begin
  select tag_code into v_code from public.pets where id = p_pet and owner_id = auth.uid();
  if not found then raise exception '找不到這筆毛孩檔案'; end if;
  while v_code is null and v_try < 6 loop
    v_try := v_try + 1;
    -- 10 碼，避開容易看錯的 0 O 1 I L
    select string_agg(substr('23456789ABCDEFGHJKMNPQRSTUVWXYZ', (get_byte(b, i) % 31) + 1, 1), '') into v_code
      from (select gen_random_bytes(10) as b) x, generate_series(0, 9) i;
    if exists (select 1 from public.pets where tag_code = v_code) then v_code := null; end if;
  end loop;
  if v_code is null then raise exception '產生代碼失敗，請再試一次'; end if;
  update public.pets set tag_code = v_code, tag_on = coalesce(p_on, false),
         tag_phone = nullif(left(regexp_replace(coalesce(p_phone, ''), '[^0-9+#, -]', '', 'g'), 20), ''),
         tag_note = nullif(left(btrim(coalesce(p_note, '')), 200), '')
   where id = p_pet and owner_id = auth.uid();
  return v_code;
end $$;
revoke all on function public.pet_tag_set(uuid, boolean, text, text) from public, anon;
grant execute on function public.pet_tag_set(uuid, boolean, text, text) to authenticated;

-- 4) 公開：名牌頁要顯示的資料（只給名字、外觀、第一張照片、飼主選擇公開的電話和留言）
create or replace function public.pet_tag_view(p_code text)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'name', p.name, 'species', p.species, 'breed', p.breed, 'sex', p.sex, 'colour', p.colour,
    'photo', p.photos[1], 'phone', p.tag_phone, 'note', p.tag_note, 'has_chip', coalesce(p.has_chip, false))
    from public.pets p
   where p.tag_code = upper(btrim(p_code)) and p.tag_on
     and not exists (select 1 from public.bans b where b.user_id = p.owner_id and (b.expires_at is null or b.expires_at > now()))
$$;
revoke all on function public.pet_tag_view(text) from public;
grant execute on function public.pet_tag_view(text) to anon, authenticated;

-- 5) 公開：記一次掃描（撿到的人按「通知飼主」時呼叫，可以帶位置、留言、聯絡方式）
--    同一隻毛孩每小時最多 8 筆、全站每小時 300 筆，避免被人拿來洗通知
create or replace function public.pet_tag_scan(p_code text, p_lat double precision, p_lng double precision, p_acc real, p_msg text, p_contact text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pet uuid; v_id uuid;
begin
  select id into v_pet from public.pets where tag_code = upper(btrim(p_code)) and tag_on;
  if v_pet is null then raise exception '這個名牌目前沒有啟用'; end if;
  perform pg_advisory_xact_lock(hashtext('tag_scan:' || v_pet::text));
  if (select count(*) from public.pet_tag_scans where pet_id = v_pet and created_at > now() - interval '1 hour') >= 8
     or (select count(*) from public.pet_tag_scans where created_at > now() - interval '1 hour') >= 300 then
    raise exception '剛剛已經通知過飼主了，請直接打電話或稍後再試';
  end if;
  if p_lat is not null and (p_lat < 20 or p_lat > 27 or p_lng < 117 or p_lng > 123.5) then p_lat := null; p_lng := null; p_acc := null; end if;   -- 只收台灣範圍內的位置
  insert into public.pet_tag_scans (pet_id, lat, lng, acc, msg, contact)
  values (v_pet, p_lat, p_lng, p_acc, nullif(left(btrim(coalesce(p_msg, '')), 300), ''), nullif(left(btrim(coalesce(p_contact, '')), 60), ''))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.pet_tag_scan(text, double precision, double precision, real, text, text) from public;
grant execute on function public.pet_tag_scan(text, double precision, double precision, real, text, text) to anon, authenticated;

select count(*) as pets_with_tag from public.pets where tag_code is not null;

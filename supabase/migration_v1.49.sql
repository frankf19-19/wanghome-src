-- 汪喵回家 migration v1.49 — 會員私訊（可重複執行）
--   對話 chats：kind = case（走失案件：協尋的人 ↔ 飼主）／found（撿到通報：飼主 ↔ 通報者）／dm（會員互傳）
--   訊息 chat_messages：文字、照片（私密空間 chat/<對話>/…，只有對話裡的人看得到）、ask（請對方證明是飼主）
--   只能透過函式送訊息：會檢查封鎖、停權、頻率；陌生人在對方回覆前最多 3 則
--   封鎖 user_blocks；檢舉沿用 reports（新增 message、user 兩種）

-- ── 資料表 ───────────────────────────────────────────────
create table if not exists public.chats (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('case','found','dm')),
  case_id     uuid references public.cases(id) on delete cascade,
  found_id    uuid references public.found_reports(id) on delete cascade,
  created_at  timestamptz not null default now(),
  last_at     timestamptz not null default now(),
  last_text   text,
  last_sender uuid
);
create index if not exists chats_case_idx on public.chats(case_id);
create index if not exists chats_found_idx on public.chats(found_id);

create table if not exists public.chat_members (
  chat_id      uuid not null references public.chats(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         text not null default 'member' check (role in ('owner','helper','member')),
  last_read_at timestamptz not null default now(),
  hidden       boolean not null default false,
  pushed_at    timestamptz,
  primary key (chat_id, user_id)
);
create index if not exists chat_members_user_idx on public.chat_members(user_id);

create table if not exists public.chat_messages (
  id         bigint generated always as identity primary key,
  chat_id    uuid not null references public.chats(id) on delete cascade,
  sender_id  uuid references auth.users(id) on delete set null,
  kind       text not null default 'text' check (kind in ('text','photo','ask','system')),
  body       text,
  photo      text,
  created_at timestamptz not null default now(),
  constraint chat_messages_len check (char_length(coalesce(body,'')) <= 2000 and char_length(coalesce(photo,'')) <= 200)
);
create index if not exists chat_messages_chat_idx on public.chat_messages(chat_id, id desc);
create index if not exists chat_messages_sender_idx on public.chat_messages(sender_id, created_at desc);

create table if not exists public.user_blocks (
  blocker    uuid not null references auth.users(id) on delete cascade,
  blocked    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked)
);

-- 會員可以關掉「讓其他會員傳訊息給我」（案件相關的對話不受影響）
alter table public.profiles add column if not exists dm_open boolean not null default true;

-- ── 權限 ─────────────────────────────────────────────────
alter table public.chats         enable row level security;
alter table public.chat_members  enable row level security;
alter table public.chat_messages enable row level security;
alter table public.user_blocks   enable row level security;
revoke all on public.chats, public.chat_members, public.chat_messages, public.user_blocks from anon, authenticated;
grant select on public.chats, public.chat_members, public.chat_messages to authenticated;
grant select on public.user_blocks to authenticated;
grant all on public.chats, public.chat_members, public.chat_messages, public.user_blocks to service_role;

create or replace function public.is_chat_member(p_chat uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.chat_members where chat_id = p_chat and user_id = auth.uid());
$$;
create or replace function public.is_chat_member_txt(p_chat text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.chat_members where chat_id::text = p_chat and user_id = auth.uid());
$$;
revoke all on function public.is_chat_member(uuid), public.is_chat_member_txt(text) from public, anon;
grant execute on function public.is_chat_member(uuid), public.is_chat_member_txt(text) to authenticated;

drop policy if exists "chat members read chats" on public.chats;
create policy "chat members read chats" on public.chats for select to authenticated using (public.is_chat_member(id));
drop policy if exists "chat members read members" on public.chat_members;
create policy "chat members read members" on public.chat_members for select to authenticated using (public.is_chat_member(chat_id));
drop policy if exists "chat members read messages" on public.chat_messages;
create policy "chat members read messages" on public.chat_messages for select to authenticated using (public.is_chat_member(chat_id));
drop policy if exists "own blocks read" on public.user_blocks;
create policy "own blocks read" on public.user_blocks for select to authenticated using (blocker = auth.uid());

-- 新訊息即時出現（Realtime 一樣會套用上面的權限）
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages') then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
exception when undefined_object then null; end $$;

-- ── 照片空間（私密）：chat/<對話編號>/<檔名> ─────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat', 'chat', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 3145728,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];
drop policy if exists "chat photo read"   on storage.objects;
drop policy if exists "chat photo upload" on storage.objects;
create policy "chat photo read" on storage.objects for select to authenticated
  using (bucket_id = 'chat' and public.is_chat_member_txt((storage.foldername(name))[1]));
create policy "chat photo upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat' and public.is_chat_member_txt((storage.foldername(name))[1]));

-- ── 檢舉：多兩種對象 ─────────────────────────────────────
alter table public.reports drop constraint if exists reports_target_type_check;
alter table public.reports add constraint reports_target_type_check check (target_type in ('case','found','sighting','message','user'));

-- ── 函式 ─────────────────────────────────────────────────
create or replace function public.chat_blocked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a));
$$;
revoke all on function public.chat_blocked(uuid, uuid) from public, anon, authenticated;

-- 開啟（或找回）一個對話，回傳對話編號
create or replace function public.chat_open(p_kind text, p_ref uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); other uuid; cid uuid; ok boolean;
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
    if not ok then raise exception '這位會員目前不接受私訊'; end if;
  else raise exception '格式錯誤'; end if;
  if other = me then raise exception '這是你自己的'; end if;
  if public.chat_blocked(me, other) then raise exception '無法傳訊息給這位會員'; end if;
  -- 已經有同一個主題、同兩個人的對話就沿用
  select c.id into cid from public.chats c
    join public.chat_members a on a.chat_id = c.id and a.user_id = me
    join public.chat_members b on b.chat_id = c.id and b.user_id = other
   where c.kind = p_kind
     and (p_kind <> 'case' or c.case_id = p_ref)
     and (p_kind <> 'found' or c.found_id = p_ref)
   limit 1;
  if cid is not null then
    update public.chat_members set hidden = false where chat_id = cid and user_id = me;
    return cid;
  end if;
  -- 防洗：一天最多開 20 個新對話
  if (select count(*) from public.chat_members m join public.chats c on c.id = m.chat_id
       where m.user_id = me and c.created_at > now() - interval '1 day') >= 20 then
    raise exception '今天開的新對話太多了，明天再試';
  end if;
  insert into public.chats(kind, case_id, found_id)
    values (p_kind, case when p_kind = 'case' then p_ref end, case when p_kind = 'found' then p_ref end)
    returning id into cid;
  insert into public.chat_members(chat_id, user_id, role) values
    (cid, me, case when p_kind = 'dm' then 'member' else 'helper' end),
    (cid, other, case when p_kind = 'dm' then 'member' else 'owner' end);
  return cid;
end $$;

-- 送訊息，回傳訊息編號
create or replace function public.chat_send(p_chat uuid, p_kind text, p_body text, p_photo text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); other uuid; mid bigint; replied boolean; k text := coalesce(p_kind, 'text'); b text := btrim(coalesce(p_body, ''));
begin
  if me is null then raise exception '請先登入'; end if;
  if not public.is_chat_member(p_chat) then raise exception '找不到這個對話'; end if;
  if public.is_banned() then raise exception '帳號暫停使用'; end if;
  if k not in ('text','photo','ask') then raise exception '格式錯誤'; end if;
  if k = 'photo' then
    if coalesce(p_photo, '') !~ ('^' || p_chat::text || '/[A-Za-z0-9_-]{8,60}\.(jpg|png|webp)$') then raise exception '照片格式錯誤'; end if;
  else
    p_photo := null;
    if b = '' then raise exception '請輸入訊息'; end if;
  end if;
  if char_length(b) > 2000 then raise exception '訊息太長（最多 2000 字）'; end if;
  select user_id into other from public.chat_members where chat_id = p_chat and user_id <> me limit 1;
  if other is null then raise exception '對方已經不在這個對話'; end if;
  if public.chat_blocked(me, other) then raise exception '無法傳訊息給這位會員'; end if;
  -- 頻率限制：每分鐘 20 則、每天 500 則
  if (select count(*) from public.chat_messages where sender_id = me and created_at > now() - interval '1 minute') >= 20 then raise exception '傳太快了，等一下再傳'; end if;
  if (select count(*) from public.chat_messages where sender_id = me and created_at > now() - interval '1 day') >= 500 then raise exception '今天傳太多訊息了，明天再試'; end if;
  -- 會員互傳：對方還沒回覆前，最多傳 3 則（避免陌生人洗訊息）
  if (select kind from public.chats where id = p_chat) = 'dm' then
    select exists (select 1 from public.chat_messages where chat_id = p_chat and sender_id = other) into replied;
    if not replied and (select count(*) from public.chat_messages where chat_id = p_chat and sender_id = me) >= 3 then
      raise exception '對方回覆之前，最多只能傳 3 則訊息';
    end if;
  end if;
  insert into public.chat_messages(chat_id, sender_id, kind, body, photo)
    values (p_chat, me, k, nullif(b, ''), p_photo) returning id into mid;
  update public.chats set last_at = now(), last_sender = me,
    last_text = left(case when k = 'photo' then '［照片］' || coalesce(' ' || nullif(b, ''), '') when k = 'ask' then '［請你證明是飼主］' else b end, 80)
   where id = p_chat;
  update public.chat_members set hidden = false where chat_id = p_chat;
  update public.chat_members set last_read_at = now() where chat_id = p_chat and user_id = me;
  return mid;
end $$;

-- 我的對話清單
create or replace function public.chat_list() returns table(
  chat_id uuid, kind text, case_id uuid, found_id uuid, title text, photo text,
  other_id uuid, other_name text, other_avatar text, my_role text,
  last_at timestamptz, last_text text, last_sender uuid, unread integer)
language sql stable security definer set search_path = public as $$
  select c.id, c.kind, c.case_id, c.found_id,
         case when c.kind = 'case' then cs.name
              when c.kind = 'found' then case f.kind when 'injured' then '受傷通報' when 'found' then '撿到通報' else '目擊通報' end
              else null end,
         case when c.kind = 'case' then cs.photos[1] when c.kind = 'found' then f.photos[1] end,
         o.user_id, p.username, p.avatar_url, m.role,
         c.last_at, c.last_text, c.last_sender,
         (select count(*)::int from public.chat_messages x where x.chat_id = c.id and x.sender_id <> auth.uid() and x.created_at > m.last_read_at)
    from public.chat_members m
    join public.chats c on c.id = m.chat_id
    left join public.chat_members o on o.chat_id = c.id and o.user_id <> m.user_id
    left join public.profiles p on p.id = o.user_id
    left join public.cases cs on cs.id = c.case_id
    left join public.found_reports f on f.id = c.found_id
   where m.user_id = auth.uid() and not m.hidden
     and exists (select 1 from public.chat_messages x where x.chat_id = c.id)
   order by c.last_at desc
   limit 200;
$$;

-- 未讀總數（鈴鐺／分頁上的數字）
create or replace function public.chat_unread() returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(sum((select count(*) from public.chat_messages x where x.chat_id = m.chat_id and x.sender_id <> auth.uid() and x.created_at > m.last_read_at)), 0)::int
    from public.chat_members m where m.user_id = auth.uid() and not m.hidden;
$$;

-- 對話裡的人（名字、大頭貼、是不是被我封鎖）
create or replace function public.chat_people(p_chat uuid) returns table(user_id uuid, username text, avatar_url text, role text, blocked boolean, joined timestamptz)
language sql stable security definer set search_path = public as $$
  select m.user_id, p.username, p.avatar_url, m.role,
         exists (select 1 from public.user_blocks b where b.blocker = auth.uid() and b.blocked = m.user_id),
         u.created_at
    from public.chat_members m
    left join public.profiles p on p.id = m.user_id
    left join auth.users u on u.id = m.user_id
   where m.chat_id = p_chat and public.is_chat_member(p_chat);
$$;

create or replace function public.chat_read(p_chat uuid) returns void
language sql security definer set search_path = public as $$
  update public.chat_members set last_read_at = now() where chat_id = p_chat and user_id = auth.uid();
$$;
create or replace function public.chat_hide(p_chat uuid) returns void
language sql security definer set search_path = public as $$
  update public.chat_members set hidden = true, last_read_at = now() where chat_id = p_chat and user_id = auth.uid();
$$;

create or replace function public.user_block(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if p_user is null or p_user = auth.uid() then return; end if;
  if p_on then insert into public.user_blocks(blocker, blocked) values (auth.uid(), p_user) on conflict do nothing;
  else delete from public.user_blocks where blocker = auth.uid() and blocked = p_user; end if;
end $$;

-- 會員公開資料（用使用者名稱找）：只給名字、大頭貼、加入時間、能不能私訊
create or replace function public.member_card(p_username text) returns table(user_id uuid, username text, avatar_url text, joined timestamptz, dm_open boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.avatar_url, p.created_at, p.dm_open
    from public.profiles p where lower(p.username) = lower(p_username) and p.username is not null limit 1;
$$;

-- 案件／通報是不是有綁定會員（決定要不要顯示「傳訊息」按鈕）
create or replace function public.chat_can(p_kind text, p_ref uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_kind
    when 'case'  then exists (select 1 from public.cases where id = p_ref and owner_id is not null and owner_id is distinct from auth.uid() and not coalesce(hidden, false))
    when 'found' then exists (select 1 from public.found_reports where id = p_ref and owner_id is not null and owner_id is distinct from auth.uid() and not coalesce(hidden, false))
    else false end;
$$;

-- 檢舉對話裡的對方：把對方最近的訊息一起附給站長看（站長平常看不到私訊內容）
create or replace function public.chat_report(p_chat uuid, p_reason text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare other uuid; snap text;
begin
  if auth.uid() is null or not public.is_chat_member(p_chat) then raise exception '找不到這個對話'; end if;
  select user_id into other from public.chat_members where chat_id = p_chat and user_id <> auth.uid() limit 1;
  if other is null then return; end if;
  if exists (select 1 from public.reports where target_type = 'user' and target_id = other and reporter_id = auth.uid() and not resolved) then return; end if;
  select string_agg(to_char(created_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || ' ' || coalesce(body, '［照片］'), E'\n' order by id)
    into snap from (select * from public.chat_messages where chat_id = p_chat and sender_id = other order by id desc limit 10) t;
  insert into public.reports (target_type, target_id, reason, note, reporter_id)
  values ('user', other, left(coalesce(p_reason, 'other'), 50), left(coalesce(p_note, '') || E'\n［私訊 ' || p_chat::text || E'］\n' || coalesce(snap, ''), 500), auth.uid());
end $$;

revoke all on function public.chat_open(text, uuid), public.chat_send(uuid, text, text, text), public.chat_list(), public.chat_unread(),
  public.chat_people(uuid), public.chat_read(uuid), public.chat_hide(uuid), public.user_block(uuid, boolean),
  public.member_card(text), public.chat_can(text, uuid), public.chat_report(uuid, text, text) from public, anon;
grant execute on function public.chat_open(text, uuid), public.chat_send(uuid, text, text, text), public.chat_list(), public.chat_unread(),
  public.chat_people(uuid), public.chat_read(uuid), public.chat_hide(uuid), public.user_block(uuid, boolean),
  public.member_card(text), public.chat_report(uuid, text, text) to authenticated;
grant execute on function public.chat_can(text, uuid) to anon, authenticated;

select 'WangHome migration v1.49 installed' as result;

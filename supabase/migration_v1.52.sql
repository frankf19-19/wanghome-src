-- 汪喵回家 migration v1.52 — 好友（可重複執行）
--   1. 每個會員一組 6 碼好友碼（給別人掃 QR 或輸入就能加）
--   2. 好友邀請：送出 → 對方接受才成為好友；對方也剛好邀請你時直接成為好友
--   3. 找人只接受「完整的好友碼或會員名稱」，不能模糊搜尋（避免陌生人一個一個找）
--   4. 好友之間私訊：沒有「對方回覆前最多 3 則」的限制，對方關掉「接受私訊」也能傳
--   5. 封鎖會一併解除好友

alter table public.profiles add column if not exists friend_code text;
create unique index if not exists profiles_friend_code_idx on public.profiles(friend_code) where friend_code is not null;

create table if not exists public.friends (
  a          uuid not null references auth.users(id) on delete cascade,   -- 兩人之中 id 比較小的
  b          uuid not null references auth.users(id) on delete cascade,   -- 兩人之中 id 比較大的
  requester  uuid not null references auth.users(id) on delete cascade,   -- 誰送出邀請
  status     text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  pushed_at  timestamptz,
  primary key (a, b),
  check (a < b)
);
create index if not exists friends_b_idx on public.friends(b);
alter table public.friends enable row level security;
revoke all on public.friends from anon, authenticated;
grant all on public.friends to service_role;

create or replace function public.are_friends(x uuid, y uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.friends where a = least(x, y) and b = greatest(x, y) and status = 'accepted');
$$;
revoke all on function public.are_friends(uuid, uuid) from public, anon, authenticated;

-- 我的好友碼（第一次用時產生）
create or replace function public.friend_code() returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c text; alpha text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ'; i int;
begin
  if me is null then raise exception '請先登入'; end if;
  select friend_code into c from public.profiles where id = me;
  if c is not null then return c; end if;
  if not exists (select 1 from public.profiles where id = me and username is not null) then raise exception '請先設定會員名稱'; end if;
  loop
    c := '';
    for i in 1..6 loop c := c || substr(alpha, 1 + floor(random() * length(alpha))::int, 1); end loop;
    begin
      update public.profiles set friend_code = c where id = me and friend_code is null;
      exit;
    exception when unique_violation then
      -- 重複了，再產生一次
    end;
  end loop;
  select friend_code into c from public.profiles where id = me;
  return c;
end $$;

-- 和某位會員的關係：self / friend / sent（我送出邀請）/ received（對方邀請我）/ none
create or replace function public.friend_rel(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null then 'none'
    when p_user = auth.uid() then 'self'
    else coalesce((select case when f.status = 'accepted' then 'friend' when f.requester = auth.uid() then 'sent' else 'received' end
                     from public.friends f where f.a = least(auth.uid(), p_user) and f.b = greatest(auth.uid(), p_user)), 'none') end;
$$;

-- 用好友碼或會員名稱找人（只接受完全相符）
create or replace function public.friend_find(p_q text) returns table(user_id uuid, username text, avatar_url text, joined timestamptz, rel text)
language plpgsql stable security definer set search_path = public as $$
declare q text := btrim(coalesce(p_q, ''));
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  q := regexp_replace(q, '^.*#/add/', '');   -- 貼整個邀請連結也可以
  q := regexp_replace(q, '^@', '');
  if char_length(q) < 2 or char_length(q) > 40 then return; end if;
  return query
    select p.id, p.username, p.avatar_url, p.created_at, public.friend_rel(p.id)
      from public.profiles p
     where p.username is not null
       and (p.friend_code = upper(q) or lower(p.username) = lower(q))
       and not exists (select 1 from public.user_blocks x where x.blocker = p.id and x.blocked = auth.uid())
     order by (p.friend_code = upper(q)) desc
     limit 1;
end $$;

-- 加好友：送出邀請；對方已經邀請我的話直接成為好友。回傳新的關係
create or replace function public.friend_add(p_user uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.friends;
begin
  if me is null then raise exception '請先登入'; end if;
  if public.is_banned() then raise exception '帳號暫停使用'; end if;
  if p_user is null or p_user = me then raise exception '不能加自己'; end if;
  if not exists (select 1 from public.profiles where id = me and username is not null) then raise exception '請先設定會員名稱'; end if;
  if not exists (select 1 from public.profiles where id = p_user and username is not null) then raise exception '找不到這位會員'; end if;
  if public.chat_blocked(me, p_user) then raise exception '無法加這位會員為好友'; end if;
  select * into r from public.friends where a = least(me, p_user) and b = greatest(me, p_user);
  if found then
    if r.status = 'accepted' then return 'friend'; end if;
    if r.requester = me then return 'sent'; end if;
    update public.friends set status = 'accepted', accepted_at = now(), pushed_at = null where a = r.a and b = r.b;
    return 'friend';
  end if;
  if (select count(*) from public.friends where requester = me and created_at > now() - interval '1 day') >= 30 then
    raise exception '今天送出的好友邀請太多了，明天再試';
  end if;
  insert into public.friends(a, b, requester) values (least(me, p_user), greatest(me, p_user), me);
  return 'sent';
end $$;

-- 回覆邀請：接受或略過
create or replace function public.friend_respond(p_user uuid, p_accept boolean) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception '請先登入'; end if;
  if p_accept then
    update public.friends set status = 'accepted', accepted_at = now(), pushed_at = null
     where a = least(me, p_user) and b = greatest(me, p_user) and requester = p_user and status = 'pending';
    return public.friend_rel(p_user);
  end if;
  delete from public.friends where a = least(me, p_user) and b = greatest(me, p_user) and requester = p_user and status = 'pending';
  return 'none';
end $$;

-- 刪除好友或取消邀請
create or replace function public.friend_remove(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  delete from public.friends where a = least(auth.uid(), p_user) and b = greatest(auth.uid(), p_user);
end $$;

-- 好友清單（含邀請）
create or replace function public.friend_list() returns table(user_id uuid, username text, avatar_url text, rel text, since timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, p.username, p.avatar_url,
         case when f.status = 'accepted' then 'friend' when f.requester = auth.uid() then 'sent' else 'received' end,
         coalesce(f.accepted_at, f.created_at)
    from public.friends f
    cross join lateral (select case when f.a = auth.uid() then f.b else f.a end as id) o
    join public.profiles p on p.id = o.id
   where auth.uid() in (f.a, f.b)
     and not public.chat_blocked(auth.uid(), o.id)
   order by (f.status = 'pending' and f.requester <> auth.uid()) desc, p.username;
$$;

-- 待回覆的好友邀請數（紅點用）
create or replace function public.friend_pending() returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.friends f
   where auth.uid() in (f.a, f.b) and f.status = 'pending' and f.requester <> auth.uid()
     and not public.chat_blocked(f.a, f.b);
$$;

-- 封鎖時一併解除好友
create or replace function public.user_block(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if p_user is null or p_user = auth.uid() then return; end if;
  if p_on then
    insert into public.user_blocks(blocker, blocked) values (auth.uid(), p_user) on conflict do nothing;
    delete from public.friends where a = least(auth.uid(), p_user) and b = greatest(auth.uid(), p_user);
  else delete from public.user_blocks where blocker = auth.uid() and blocked = p_user; end if;
end $$;

-- 開對話：好友之間，對方關掉「接受私訊」也可以開
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
  else raise exception '格式錯誤'; end if;
  if other = me then raise exception '這是你自己的'; end if;
  if public.chat_blocked(me, other) then raise exception '無法傳訊息給這位會員'; end if;
  select c.id into cid from public.chats c
    join public.chat_members a on a.chat_id = c.id and a.user_id = me
    join public.chat_members b on b.chat_id = c.id and b.user_id = other
   where c.kind = p_kind
     and (p_kind <> 'case' or c.case_id = p_ref)
     and (p_kind <> 'found' or c.found_id = p_ref)
   order by c.created_at limit 1;
  if cid is not null then
    update public.chat_members set hidden = false where chat_id = cid and user_id = me;
    return cid;
  end if;
  if p_kind = 'dm' and not ok and not public.are_friends(me, other) then raise exception '這位會員目前不接受私訊'; end if;
  if p_kind = 'case' and not exists (select 1 from public.cases where id = p_ref and status = 'searching') then raise exception '這個案件已經結案了'; end if;
  if p_kind = 'found' and not exists (select 1 from public.found_reports where id = p_ref and status = 'open') then raise exception '這則通報已經結案了'; end if;
  if (select count(*) from public.chats where created_by = me and created_at > now() - interval '1 day') >= 20 then
    raise exception '今天開的新對話太多了，明天再試';
  end if;
  perform pg_advisory_xact_lock(hashtext(least(me::text, other::text) || greatest(me::text, other::text) || p_kind || coalesce(p_ref::text, '')));
  select c.id into cid from public.chats c
    join public.chat_members a on a.chat_id = c.id and a.user_id = me
    join public.chat_members b on b.chat_id = c.id and b.user_id = other
   where c.kind = p_kind and (p_kind <> 'case' or c.case_id = p_ref) and (p_kind <> 'found' or c.found_id = p_ref) limit 1;
  if cid is not null then return cid; end if;
  insert into public.chats(kind, case_id, found_id, created_by)
    values (p_kind, case when p_kind = 'case' then p_ref end, case when p_kind = 'found' then p_ref end, me)
    returning id into cid;
  insert into public.chat_members(chat_id, user_id, role, last_read_at) values
    (cid, me, case when p_kind = 'dm' then 'member' else 'helper' end, now()),
    (cid, other, case when p_kind = 'dm' then 'member' else 'owner' end, now() - interval '1 second');
  return cid;
end $$;

-- 傳訊息：好友之間沒有「對方回覆前」的則數限制
create or replace function public.chat_send(p_chat uuid, p_kind text, p_body text, p_photo text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); other uuid; mid bigint; replied boolean; k text := coalesce(p_kind, 'text'); b text := btrim(coalesce(p_body, ''));
        ck text; cap int; ok boolean; fr boolean;
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
  if (select count(*) from public.chat_messages where sender_id = me and created_at > now() - interval '1 minute') >= 20 then raise exception '傳太快了，等一下再傳'; end if;
  if (select count(*) from public.chat_messages where sender_id = me and created_at > now() - interval '1 day') >= 500 then raise exception '今天傳太多訊息了，明天再試'; end if;
  fr := public.are_friends(me, other);
  select kind into ck from public.chats where id = p_chat;
  if ck = 'dm' and not fr then
    select dm_open into ok from public.profiles where id = other;
    if ok is false and not exists (select 1 from public.chat_messages where chat_id = p_chat and sender_id = other) then
      raise exception '這位會員目前不接受私訊';
    end if;
  end if;
  if not fr then
    cap := case when ck = 'dm' then 3 else 10 end;
    select exists (select 1 from public.chat_messages where chat_id = p_chat and sender_id = other) into replied;
    if not replied and (select count(*) from public.chat_messages where chat_id = p_chat and sender_id = me) >= cap then
      raise exception '對方回覆之前，最多只能傳 % 則訊息', cap;
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

-- 會員頁多帶「和我的關係」
drop function if exists public.member_card(text);
create or replace function public.member_card(p_username text) returns table(user_id uuid, username text, avatar_url text, joined timestamptz, dm_open boolean, rel text)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.avatar_url, p.created_at, p.dm_open, public.friend_rel(p.id)
    from public.profiles p where lower(p.username) = lower(p_username) and p.username is not null limit 1;
$$;

revoke all on function public.friend_code(), public.friend_rel(uuid), public.friend_find(text), public.friend_add(uuid),
  public.friend_respond(uuid, boolean), public.friend_remove(uuid), public.friend_list(), public.friend_pending(),
  public.member_card(text), public.user_block(uuid, boolean) from public, anon;
grant execute on function public.friend_code(), public.friend_rel(uuid), public.friend_find(text), public.friend_add(uuid),
  public.friend_respond(uuid, boolean), public.friend_remove(uuid), public.friend_list(), public.friend_pending(),
  public.member_card(text), public.user_block(uuid, boolean) to authenticated;

select 'WangHome migration v1.52 installed' as result;

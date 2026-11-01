-- 汪喵回家 migration v1.50 — 私訊加強（可重複執行）
--   1. 記錄對話是誰開的：「一天最多開 20 個新對話」只算自己開的（別人傳給你的不算）
--   2. 對話還沒有訊息前，看不到對方是誰（避免有人只開對話不傳訊息，就查出飼主的會員資料）
--   3. 案件／通報對話：只有協尋中（或通報還開著）才能開新對話；對方回覆前最多 10 則
--   4. 會員互傳：對方關掉「接受私訊」後，原本的對話也不能再傳
--   5. 停權的會員不能上傳照片
--   6. 管理後台的檢舉列表顯示被檢舉會員的名稱

alter table public.chats add column if not exists created_by uuid references auth.users(id) on delete set null;

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
  -- 新對話的條件
  if p_kind = 'dm' and not ok then raise exception '這位會員目前不接受私訊'; end if;
  if p_kind = 'case' and not exists (select 1 from public.cases where id = p_ref and status = 'searching') then raise exception '這個案件已經結案了'; end if;
  if p_kind = 'found' and not exists (select 1 from public.found_reports where id = p_ref and status = 'open') then raise exception '這則通報已經結案了'; end if;
  if (select count(*) from public.chats where created_by = me and created_at > now() - interval '1 day') >= 20 then
    raise exception '今天開的新對話太多了，明天再試';
  end if;
  -- 同一時間按兩下：先鎖住這兩個人，避免開出兩個一樣的對話
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

create or replace function public.chat_send(p_chat uuid, p_kind text, p_body text, p_photo text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); other uuid; mid bigint; replied boolean; k text := coalesce(p_kind, 'text'); b text := btrim(coalesce(p_body, ''));
        ck text; cap int; ok boolean;
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
  select kind into ck from public.chats where id = p_chat;
  if ck = 'dm' then
    select dm_open into ok from public.profiles where id = other;
    if ok is false and not exists (select 1 from public.chat_messages where chat_id = p_chat and sender_id = other) then
      raise exception '這位會員目前不接受私訊';
    end if;
  end if;
  -- 對方回覆之前的上限：會員互傳 3 則、案件／通報 10 則（可以先把看到的時間地點、照片傳過去）
  cap := case when ck = 'dm' then 3 else 10 end;
  select exists (select 1 from public.chat_messages where chat_id = p_chat and sender_id = other) into replied;
  if not replied and (select count(*) from public.chat_messages where chat_id = p_chat and sender_id = me) >= cap then
    raise exception '對方回覆之前，最多只能傳 % 則訊息', cap;
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

-- 對話還沒有任何訊息時，只回傳自己（看不到對方是誰）
create or replace function public.chat_people(p_chat uuid) returns table(user_id uuid, username text, avatar_url text, role text, blocked boolean, joined timestamptz)
language sql stable security definer set search_path = public as $$
  select m.user_id, p.username, p.avatar_url, m.role,
         exists (select 1 from public.user_blocks b where b.blocker = auth.uid() and b.blocked = m.user_id),
         u.created_at
    from public.chat_members m
    left join public.profiles p on p.id = m.user_id
    left join auth.users u on u.id = m.user_id
   where m.chat_id = p_chat and public.is_chat_member(p_chat)
     and (m.user_id = auth.uid() or exists (select 1 from public.chat_messages x where x.chat_id = p_chat));
$$;

-- 停權的會員不能上傳照片
create or replace function public.is_banned_me() returns boolean
language sql stable security definer set search_path = public as $$ select public.is_banned(); $$;
revoke all on function public.is_banned_me() from public, anon;
grant execute on function public.is_banned_me() to authenticated;
drop policy if exists "chat photo upload" on storage.objects;
create policy "chat photo upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat' and public.is_chat_member_txt((storage.foldername(name))[1]) and not public.is_banned_me());

-- 管理後台：檢舉會員時顯示會員名稱
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
                  case when pu.id is not null then '會員：' || coalesce(pu.username, '（未設定名稱）') end) as target_title,
         coalesce(c.hidden, f.hidden, false) as target_hidden,
         (select count(*) from public.reports r2 where r2.target_id = r.target_id and not r2.resolved) as report_count
  from public.reports r
  left join public.cases c on r.target_type = 'case' and c.id = r.target_id
  left join public.found_reports f on r.target_type = 'found' and f.id = r.target_id
  left join public.sightings s on r.target_type = 'sighting' and s.id = r.target_id
  left join public.profiles pu on r.target_type = 'user' and pu.id = r.target_id
  where p_include_resolved or not r.resolved
  order by r.resolved, r.created_at desc
  limit 300;
end $$;
revoke execute on function public.admin_reports(boolean) from anon, public;
grant execute on function public.admin_reports(boolean) to authenticated;

select 'WangHome migration v1.50 installed' as result;

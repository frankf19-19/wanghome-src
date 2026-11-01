-- 汪喵回家 migration v1.56 — 聊天：語音訊息、一次多張照片（可重複執行）

-- 私密空間多收語音檔
update storage.buckets set allowed_mime_types = array['image/jpeg','image/png','image/webp','audio/webm','audio/mp4','audio/x-m4a','audio/aac','audio/ogg','audio/mpeg']
 where id = 'chat';

alter table public.chat_messages drop constraint if exists chat_messages_kind_check;
alter table public.chat_messages add constraint chat_messages_kind_check check (kind in ('text','photo','ask','system','sticker','voice'));
alter table public.chat_messages drop constraint if exists chat_messages_len;
alter table public.chat_messages add constraint chat_messages_len check (char_length(coalesce(body,'')) <= 2000 and char_length(coalesce(photo,'')) <= 600);

create or replace function public.chat_send(p_chat uuid, p_kind text, p_body text, p_photo text default null, p_reply bigint default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); other uuid; mid bigint; replied boolean; k text := coalesce(p_kind, 'text'); b text := btrim(coalesce(p_body, ''));
        ck text; cap int; ok boolean; fr boolean; pat text;
begin
  if me is null then raise exception '請先登入'; end if;
  if not public.is_chat_member(p_chat) then raise exception '找不到這個對話'; end if;
  if public.is_banned() then raise exception '帳號暫停使用'; end if;
  if k not in ('text','photo','ask','sticker','voice') then raise exception '格式錯誤'; end if;
  if k = 'photo' then
    -- 一則訊息最多 4 張照片（用逗號隔開）
    pat := p_chat::text || '/[A-Za-z0-9_-]{8,60}\.(jpg|png|webp)';
    if coalesce(p_photo, '') !~ ('^' || pat || '(,' || pat || '){0,3}$') then raise exception '照片格式錯誤'; end if;
  elsif k = 'voice' then
    if coalesce(p_photo, '') !~ ('^' || p_chat::text || '/[A-Za-z0-9_-]{8,60}\.(webm|m4a|mp4|ogg|aac)$') then raise exception '語音格式錯誤'; end if;
    if b !~ '^[0-9]{0,3}$' then b := ''; end if;
  elsif k = 'sticker' then
    p_photo := null;
    if b !~ '^[a-z0-9_]{1,24}$' then raise exception '貼圖格式錯誤'; end if;
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
  if p_reply is not null and not exists (select 1 from public.chat_messages where id = p_reply and chat_id = p_chat) then p_reply := null; end if;
  insert into public.chat_messages(chat_id, sender_id, kind, body, photo, reply_to)
    values (p_chat, me, k, nullif(b, ''), p_photo, p_reply) returning id into mid;
  update public.chats set last_at = now(), last_sender = me,
    last_text = left(case when k = 'photo' then '［照片］' || coalesce(' ' || nullif(b, ''), '') when k = 'ask' then '［請你證明是飼主］' when k = 'sticker' then '［貼圖］' when k = 'voice' then '［語音］' else b end, 80)
   where id = p_chat;
  update public.chat_members set hidden = false where chat_id = p_chat;
  update public.chat_members set last_read_at = now() where chat_id = p_chat and user_id = me;
  return mid;
end $$;

select 'WangHome migration v1.56 installed' as result;

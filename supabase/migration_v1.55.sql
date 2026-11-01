-- 汪喵回家 migration v1.55 — 聊天：表情回應、對話靜音（可重複執行）

alter table public.chat_messages add column if not exists reactions jsonb not null default '{}'::jsonb;
alter table public.chat_members  add column if not exists muted boolean not null default false;

-- 表情回應：每個人對一則訊息只留一個表情；同一個再按一次就取消
create or replace function public.chat_react(p_id bigint, p_emoji text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid; cur jsonb; me text := auth.uid()::text;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select chat_id, reactions into cid, cur from public.chat_messages where id = p_id and not deleted;
  if cid is null or not public.is_chat_member(cid) then raise exception '找不到這則訊息'; end if;
  if p_emoji is not null and p_emoji not in ('❤️','😂','👍','😮','😢','🙏') then raise exception '格式錯誤'; end if;
  if p_emoji is null or cur->>me = p_emoji then cur := cur - me; else cur := cur || jsonb_build_object(me, p_emoji); end if;
  update public.chat_messages set reactions = cur where id = p_id;
  return cur;
end $$;

-- 對話靜音：不收這個對話的推播
create or replace function public.chat_mute(p_chat uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_chat_member(p_chat) then raise exception '找不到這個對話'; end if;
  update public.chat_members set muted = coalesce(p_on, false) where chat_id = p_chat and user_id = auth.uid();
end $$;

revoke all on function public.chat_react(bigint, text), public.chat_mute(uuid, boolean) from public, anon;
grant execute on function public.chat_react(bigint, text), public.chat_mute(uuid, boolean) to authenticated;

select 'WangHome migration v1.55 installed' as result;

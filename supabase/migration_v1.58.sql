-- 汪喵回家 migration v1.58 — 訊息列表：置頂、標為未讀、顯示靜音（可重複執行）
alter table public.chat_members add column if not exists pinned_at timestamptz;

drop function if exists public.chat_list();
create function public.chat_list() returns table(
  chat_id uuid, kind text, case_id uuid, found_id uuid, title text, photo text,
  other_id uuid, other_name text, other_avatar text, my_role text,
  last_at timestamptz, last_text text, last_sender uuid, unread integer, muted boolean, pinned boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.kind, c.case_id, c.found_id,
         case when c.kind = 'case' then cs.name
              when c.kind = 'found' then case f.kind when 'injured' then '受傷通報' when 'found' then '撿到通報' else '目擊通報' end
              else null end,
         case when c.kind = 'case' then cs.photos[1] when c.kind = 'found' then f.photos[1] end,
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
   where m.user_id = auth.uid() and not m.hidden
     and exists (select 1 from public.chat_messages x where x.chat_id = c.id)
   order by m.pinned_at desc nulls last, c.last_at desc
   limit 200;
$$;

create or replace function public.chat_pin(p_chat uuid, p_on boolean) returns void
language sql security definer set search_path = public as $$
  update public.chat_members set pinned_at = case when p_on then now() else null end where chat_id = p_chat and user_id = auth.uid();
$$;

-- 標為未讀：把「已讀到」退回對方最後一則訊息之前
create or replace function public.chat_mark_unread(p_chat uuid) returns void
language sql security definer set search_path = public as $$
  update public.chat_members m set last_read_at = coalesce(
      (select max(x.created_at) - interval '1 millisecond' from public.chat_messages x where x.chat_id = p_chat and x.sender_id <> auth.uid()), m.last_read_at)
   where m.chat_id = p_chat and m.user_id = auth.uid();
$$;

-- 全部標為已讀
create or replace function public.chat_read_all() returns void
language sql security definer set search_path = public as $$
  update public.chat_members set last_read_at = now() where user_id = auth.uid() and not hidden;
$$;

revoke all on function public.chat_list(), public.chat_pin(uuid, boolean), public.chat_mark_unread(uuid), public.chat_read_all() from public, anon;
grant execute on function public.chat_list(), public.chat_pin(uuid, boolean), public.chat_mark_unread(uuid), public.chat_read_all() to authenticated;
select 'WangHome migration v1.58 installed' as result;

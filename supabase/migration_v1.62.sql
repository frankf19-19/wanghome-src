-- 汪喵回家 migration v1.62 — 揪團約玩：活動頁的大家一起聊（群組留言板）
--   登入的會員都看得到、都可以留言；發起人可以刪任何一則，其他人只能刪自己的。
--   可重複執行。

create table if not exists public.pet_meet_msgs (
  id         bigint generated always as identity primary key,
  meet_id    uuid not null references public.pet_meets(id) on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index if not exists pet_meet_msgs_meet_idx on public.pet_meet_msgs(meet_id, id);
alter table public.pet_meet_msgs enable row level security;
drop policy if exists "pet_meet_msgs insert" on public.pet_meet_msgs;
create policy "pet_meet_msgs insert" on public.pet_meet_msgs for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "pet_meet_msgs delete" on public.pet_meet_msgs;
create policy "pet_meet_msgs delete" on public.pet_meet_msgs for delete to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.pet_meets m where m.id = meet_id and m.owner_id = auth.uid()));

create or replace function public.pet_meet_msgs_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.pet_meets where id = new.meet_id and not hidden and starts_at > now() - interval '1 day') then
    raise exception '這個活動已經結束';
  end if;
  if (select count(*) from public.pet_meet_msgs where user_id = new.user_id and created_at > now() - interval '1 minute') >= 6 then
    raise exception '留言太快了，請稍等一下';
  end if;
  if not public.pals_text_ok(new.body) then raise exception '交朋友區禁止買賣、配種相關內容'; end if;
  if exists (select 1 from public.bans b where b.user_id = new.user_id and (b.expires_at is null or b.expires_at > now())) then
    raise exception '帳號已停權';
  end if;
  return new;
end $$;
drop trigger if exists pet_meet_msgs_guard on public.pet_meet_msgs;
create trigger pet_meet_msgs_guard before insert on public.pet_meet_msgs for each row execute function public.pet_meet_msgs_guard();

create or replace view public.pet_meet_board with (security_invoker = false) as
  select x.id, x.meet_id, x.user_id, x.body, x.created_at, p.username, p.avatar_url
    from public.pet_meet_msgs x join public.profiles p on p.id = x.user_id
   where p.username is not null
     and not exists (select 1 from public.bans b where b.user_id = x.user_id and (b.expires_at is null or b.expires_at > now()));
revoke all on public.pet_meet_board from anon;
grant select on public.pet_meet_board to authenticated;

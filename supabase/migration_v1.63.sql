-- 汪喵回家 migration v1.63 — 毛孩交朋友：「喜歡」毛孩名片
--   登入的會員可以喜歡別人的毛孩名片；飼主看得到「誰喜歡你的毛孩」。
--   名片牆顯示喜歡的人數。不能喜歡自己的毛孩。
--   可重複執行。

create table if not exists public.pet_card_likes (
  pet_id     uuid not null references public.pet_cards(pet_id) on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (pet_id, user_id)
);
create index if not exists pet_card_likes_user_idx on public.pet_card_likes(user_id);
alter table public.pet_card_likes enable row level security;
drop policy if exists "pet_card_likes insert" on public.pet_card_likes;
create policy "pet_card_likes insert" on public.pet_card_likes for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "pet_card_likes delete" on public.pet_card_likes;
create policy "pet_card_likes delete" on public.pet_card_likes for delete to authenticated using (user_id = auth.uid());
drop policy if exists "pet_card_likes select" on public.pet_card_likes;
create policy "pet_card_likes select" on public.pet_card_likes for select to authenticated using (user_id = auth.uid());

create or replace function public.pet_card_likes_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.pet_cards where pet_id = new.pet_id and not hidden) then
    raise exception '這張名片已經不在了';
  end if;
  if exists (select 1 from public.pet_cards where pet_id = new.pet_id and owner_id = new.user_id) then
    raise exception '不能喜歡自己的毛孩';
  end if;
  if (select count(*) from public.pet_card_likes where user_id = new.user_id and created_at > now() - interval '1 hour') >= 60 then
    raise exception '按太快了，請稍等一下';
  end if;
  if exists (select 1 from public.bans b where b.user_id = new.user_id and (b.expires_at is null or b.expires_at > now())) then
    raise exception '帳號已停權';
  end if;
  return new;
end $$;
drop trigger if exists pet_card_likes_guard on public.pet_card_likes;
create trigger pet_card_likes_guard before insert on public.pet_card_likes for each row execute function public.pet_card_likes_guard();

-- 名片牆：加上喜歡人數（加在最後一欄，舊的欄位不變）
create or replace view public.pet_cards_public with (security_invoker = false) as
  select c.pet_id, c.owner_id, c.species, c.name, c.breed, c.sex, c.size, c.age_text, c.tags, c.intro,
         c.city, c.district, c.photo, c.updated_at, p.username, p.avatar_url,
         (select count(*) from public.pet_card_likes l where l.pet_id = c.pet_id)::int as likes
    from public.pet_cards c join public.profiles p on p.id = c.owner_id
   where not c.hidden and p.username is not null
     and not exists (select 1 from public.bans b where b.user_id = c.owner_id and (b.expires_at is null or b.expires_at > now()));
grant select on public.pet_cards_public to anon, authenticated;

-- 誰喜歡我的毛孩：只有飼主自己看得到
create or replace view public.pet_card_likers with (security_invoker = false) as
  select l.pet_id, c.name as pet_name, l.user_id, l.created_at, p.username, p.avatar_url
    from public.pet_card_likes l
    join public.pet_cards c on c.pet_id = l.pet_id
    join public.profiles p on p.id = l.user_id
   where c.owner_id = auth.uid() and p.username is not null
     and not exists (select 1 from public.bans b where b.user_id = l.user_id and (b.expires_at is null or b.expires_at > now()));
revoke all on public.pet_card_likers from anon;
grant select on public.pet_card_likers to authenticated;

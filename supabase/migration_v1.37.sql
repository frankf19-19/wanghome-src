-- 汪喵回家 migration v1.37 — 毛孩相簿＋每三個月的回顧相簿
--   到 Supabase → SQL Editor 整段執行。可重複執行。
--   照片檔案放在私密空間 pet-private/<會員>/<寵物>/album/…（只有本人看得到），這裡只記路徑、拍攝日期和一句話。
create table if not exists public.pet_photos (
  id         uuid primary key default gen_random_uuid(),
  pet_id     uuid not null references public.pets(id) on delete cascade,
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  path       text not null,
  taken_on   date not null default current_date,
  caption    text,
  fav        boolean not null default false,
  created_at timestamptz not null default now(),
  constraint pet_photos_len check (char_length(path) <= 200 and char_length(coalesce(caption, '')) <= 80)
);
create index if not exists pet_photos_pet_idx on public.pet_photos(pet_id, taken_on desc, created_at desc);
create index if not exists pet_photos_owner_idx on public.pet_photos(owner_id, taken_on desc);
alter table public.pet_photos enable row level security;
drop policy if exists "own pet photos" on public.pet_photos;
create policy "own pet photos" on public.pet_photos for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
grant select, insert, update, delete on public.pet_photos to authenticated;
revoke all on public.pet_photos from anon;

-- 新增時：一定是自己、寵物一定是自己的、路徑一定在自己的資料夾；每隻毛孩最多 600 張
create or replace function public.pet_photos_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.owner_id := auth.uid();
  if new.owner_id is null then raise exception '請先登入' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.pets where id = new.pet_id and owner_id = new.owner_id) then
    raise exception '找不到這隻毛孩' using errcode = 'P0001'; end if;
  if split_part(new.path, '/', 1) <> new.owner_id::text or split_part(new.path, '/', 2) <> new.pet_id::text then
    raise exception '照片路徑不正確' using errcode = 'P0001'; end if;
  if tg_op = 'INSERT' and (select count(*) from public.pet_photos where pet_id = new.pet_id) >= 600 then
    raise exception '這隻毛孩的相簿已經滿了（最多 600 張），可以先刪掉一些' using errcode = 'P0001'; end if;
  if new.taken_on > current_date + 1 or new.taken_on < date '1990-01-01' then new.taken_on := current_date; end if;
  return new;
end $$;
drop trigger if exists pet_photos_guard on public.pet_photos;
create trigger pet_photos_guard before insert or update on public.pet_photos
  for each row execute function public.pet_photos_guard();

select 'WangHome migration v1.37 installed' as result;

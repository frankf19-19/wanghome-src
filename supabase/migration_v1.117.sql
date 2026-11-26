-- 汪喵回家 migration v1.117 — 散步日記：每次散步蓋一個腳印（日期、幾分鐘、心情貼紙、一句話、一張照片）
--   只有飼主自己看得到、改得到。可重複執行。
create table if not exists public.pet_walks (
  id         uuid primary key default gen_random_uuid(),
  pet_id     uuid not null references public.pets(id) on delete cascade,
  walked_on  date not null,
  minutes    int,
  moods      text[] not null default '{}',
  note       text,
  photo      text,
  created_at timestamptz not null default now(),
  constraint pet_walks_chk check (
    (minutes is null or minutes between 1 and 600)
    and coalesce(array_length(moods, 1), 0) <= 8
    and char_length(coalesce(note, '')) <= 300
    and char_length(coalesce(photo, '')) <= 400
    and walked_on between date '2015-01-01' and (current_date + 1))
);
create index if not exists pet_walks_pet_idx on public.pet_walks(pet_id, walked_on desc);
alter table public.pet_walks enable row level security;
revoke all on public.pet_walks from anon, authenticated;
grant select, insert, update, delete on public.pet_walks to authenticated;
grant all on public.pet_walks to service_role;
drop policy if exists "own pet walks" on public.pet_walks;
create policy "own pet walks" on public.pet_walks for all to authenticated
  using (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));
select count(*) as pet_walks_rows from public.pet_walks;

-- 汪喵回家 migration v1.120 — 散步冒險的存檔：每隻毛孩一筆（金幣、打怪經驗值、裝備、賣掉的寶物、打過的怪）。
--   只有飼主自己看得到、改得到。可重複執行。
create table if not exists public.pet_game (
  pet_id     uuid primary key references public.pets(id) on delete cascade,
  coins      int not null default 0,
  bxp        int not null default 0,
  gear       jsonb not null default '{}',
  eq         jsonb not null default '{}',
  sold       jsonb not null default '{}',
  kills      jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  constraint pet_game_chk check (
    coins between 0 and 9999999 and bxp between 0 and 9999999
    and jsonb_typeof(gear) = 'object' and jsonb_typeof(eq) = 'object' and jsonb_typeof(sold) = 'object' and jsonb_typeof(kills) = 'object'
    and pg_column_size(gear) <= 800 and pg_column_size(eq) <= 300 and pg_column_size(sold) <= 400 and pg_column_size(kills) <= 400)
);
alter table public.pet_game enable row level security;
revoke all on public.pet_game from anon, authenticated;
grant select, insert, update, delete on public.pet_game to authenticated;
grant all on public.pet_game to service_role;
drop policy if exists "own pet game" on public.pet_game;
create policy "own pet game" on public.pet_game for all to authenticated
  using (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));
select count(*) as pet_game_rows from public.pet_game;

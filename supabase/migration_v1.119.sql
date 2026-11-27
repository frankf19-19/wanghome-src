-- 汪喵回家 migration v1.119 — 散步日記的寶物：每次散步撿到的東西（{"bone":2,"ball":1}）。可重複執行。
alter table public.pet_walks add column if not exists loot jsonb;
alter table public.pet_walks drop constraint if exists pet_walks_loot_chk;
alter table public.pet_walks add constraint pet_walks_loot_chk check (loot is null or (jsonb_typeof(loot) = 'object' and pg_column_size(loot) <= 400));
select count(*) as pet_walks_rows from public.pet_walks;

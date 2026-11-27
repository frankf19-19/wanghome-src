-- 汪喵回家 migration v1.121 — 散步冒險存檔多一欄 meta（今天的任務獎勵領了沒之類的小記錄）。可重複執行。
alter table public.pet_game add column if not exists meta jsonb not null default '{}';
alter table public.pet_game drop constraint if exists pet_game_meta_chk;
alter table public.pet_game add constraint pet_game_meta_chk check (jsonb_typeof(meta) = 'object' and pg_column_size(meta) <= 400);
select count(*) as pet_game_rows from public.pet_game;

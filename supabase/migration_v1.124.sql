-- 汪喵回家 migration v1.124 — 散步冒險存檔的 meta 放大到 2000 bytes（要記今天去過哪些補給站）。可重複執行。
alter table public.pet_game drop constraint if exists pet_game_meta_chk;
alter table public.pet_game add constraint pet_game_meta_chk check (jsonb_typeof(meta) = 'object' and pg_column_size(meta) <= 2000);
select count(*) as pet_game_rows from public.pet_game;

-- 汪喵回家 migration v1.31 — 藥品／保養品可以拍照存起來（藥袋、包裝）
--   照片放在私人的 pet-private 空間（只有飼主看得到），這裡只存檔案路徑。
-- 可重複執行。
alter table public.pet_meds add column if not exists files text[] not null default '{}';
alter table public.pet_meds drop constraint if exists pet_meds_files_max;
alter table public.pet_meds add constraint pet_meds_files_max check (coalesce(array_length(files,1),0) <= 4);
select 'v1.31 ok' as result;

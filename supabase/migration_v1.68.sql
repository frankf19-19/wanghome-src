-- 汪喵回家 migration v1.68 — 毛孩名片照片可以用 pets/（毛孩檔案的照片、名片新上傳的照片）
--   原本只允許 cases/，但 cases/ 沒被案件用到的照片會被每日清理刪掉。可重複執行。
alter table public.pet_cards drop constraint if exists pet_cards_photo_check;
alter table public.pet_cards add constraint pet_cards_photo_check check (
  photo is null or photo ~ '^https://nopyhfpaykkiieudvoko\.supabase\.co/storage/v1/object/public/photos/(cases|pets)/[^\s''"<>]+$');

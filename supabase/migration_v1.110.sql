-- 汪喵回家 migration v1.110 — 自動 Reel 影片專用的公開儲存桶（photos 桶只收 1.5MB 以內的圖片）
--   只有後台（service role）能寫入；任何人可用公開網址讀（FB／IG 要抓影片）。可重複執行。
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('social', 'social', true, 15728640, array['video/mp4','image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 15728640, allowed_mime_types = array['video/mp4','image/jpeg'];
select id, public, file_size_limit from storage.buckets where id = 'social';

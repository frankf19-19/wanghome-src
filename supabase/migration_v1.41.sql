-- 汪喵回家 migration v1.41 — 收容所比對加「照片相似度」
--   到 Supabase → SQL Editor 整段執行。可重複執行。
--   排程（scripts/photo_match.py）用 AI 比對走失毛孩照片和收容所動物照片，算出 0～100 的相似度：
--   photo_sim：null＝還沒比對；-1＝其中一方沒有照片；0～100＝照片相似度
alter table public.shelter_matches add column if not exists photo_sim integer;
alter table public.shelter_matches add column if not exists photo_checked_at timestamptz;
revoke update (photo_sim, photo_checked_at) on public.shelter_matches from anon, authenticated;
create index if not exists shelter_matches_sim_idx on public.shelter_matches(photo_sim) where photo_sim is null;
select 'WangHome migration v1.41 installed' as result;

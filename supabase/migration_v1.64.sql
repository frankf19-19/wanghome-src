-- 汪喵回家 migration v1.64 — 毛孩交朋友：補上資料表權限
--   v1.61–v1.63 新建的資料表沒有給登入會員基本權限（RLS 政策還在，誰能動哪一筆仍由政策決定），
--   導致「放上名片牆」出現 permission denied for table pet_cards。可重複執行。
grant select, insert, update, delete on public.pet_cards      to authenticated;
grant select, insert, update, delete on public.pet_meets      to authenticated;
grant select, insert, delete         on public.pet_meet_joins to authenticated;
grant select, insert, delete         on public.pet_meet_msgs  to authenticated;
grant select, insert, delete         on public.pet_card_likes to authenticated;
grant usage, select on all sequences in schema public to authenticated;

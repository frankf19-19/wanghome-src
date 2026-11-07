-- 汪喵回家 migration v1.65 — 會員資料：補上「換大頭貼」「開放私訊」的更新權限
--   profiles 只開放部分欄位給會員自己改；avatar_url、dm_open 漏了，導致換大頭貼、私訊設定存不進去。
--   RLS 仍限制只能改自己的那一筆。可重複執行。
grant update (avatar_url, dm_open) on public.profiles to authenticated;

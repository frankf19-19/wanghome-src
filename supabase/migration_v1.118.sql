-- 汪喵回家 migration v1.118 — 散步日記加上路線、公里數、天氣、沿路風景照
--   路線和風景照的位置只有飼主自己看得到（同一張表的 RLS）。可重複執行。
alter table public.pet_walks add column if not exists km      numeric(6,2);
alter table public.pet_walks add column if not exists route   jsonb;   -- [[緯度,經度],…]，最多約 400 點
alter table public.pet_walks add column if not exists weather jsonb;   -- {"t":27.4,"code":2}
alter table public.pet_walks add column if not exists spots   jsonb;   -- [{"lat":..,"lng":..,"photo":".."},…] 最多 8 張
alter table public.pet_walks drop constraint if exists pet_walks_geo_chk;
alter table public.pet_walks add constraint pet_walks_geo_chk check (
  (km is null or km between 0 and 200)
  and (route is null or (jsonb_typeof(route) = 'array' and jsonb_array_length(route) <= 500 and pg_column_size(route) <= 30000))
  and (weather is null or (jsonb_typeof(weather) = 'object' and pg_column_size(weather) <= 300))
  and (spots is null or (jsonb_typeof(spots) = 'array' and jsonb_array_length(spots) <= 8 and pg_column_size(spots) <= 6000)));
select count(*) as pet_walks_rows from public.pet_walks;

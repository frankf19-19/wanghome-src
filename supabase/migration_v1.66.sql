-- 汪喵回家 migration v1.66 — 揪團約玩：集合地點可以在地圖上標位置
--   pet_meets 加上 lat / lng（選填，只限台灣範圍）；公開檢視表多兩欄。可重複執行。
alter table public.pet_meets add column if not exists lat double precision;
alter table public.pet_meets add column if not exists lng double precision;
alter table public.pet_meets drop constraint if exists pet_meets_latlng_tw;
alter table public.pet_meets add constraint pet_meets_latlng_tw check (
  (lat is null and lng is null) or (lat between 21.5 and 26.5 and lng between 118 and 122.5));

create or replace view public.pet_meets_public with (security_invoker = false) as
  select m.id, m.owner_id, m.species, m.title, m.place, m.city, m.district, m.starts_at, m.size_pref, m.note, m.cap, m.created_at,
         p.username, p.avatar_url,
         (select count(*) from public.pet_meet_joins j where j.meet_id = m.id)::int as joined,
         m.lat, m.lng
    from public.pet_meets m join public.profiles p on p.id = m.owner_id
   where not m.hidden and m.starts_at > now() - interval '3 hours' and p.username is not null
     and not exists (select 1 from public.bans b where b.user_id = m.owner_id and (b.expires_at is null or b.expires_at > now()));
grant select on public.pet_meets_public to anon, authenticated;

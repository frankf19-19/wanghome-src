-- v1.83 目擊回報可以上傳多張照片（最多 6 張）
-- photo_url 保留為第一張（舊程式、通知信、首頁最新目擊都繼續用），photos 放全部照片
alter table public.sightings add column if not exists photos text[] not null default '{}';
alter table public.sightings drop constraint if exists sightings_photos_ok;
alter table public.sightings add constraint sightings_photos_ok
  check (coalesce(array_length(photos,1),0) <= 6 and public.photo_urls_ok(photos)) not valid;
grant insert (photos) on public.sightings to anon, authenticated;

create or replace view public.sightings_public with (security_invoker = false) as
select s.id, s.case_id, s.created_at, s.seen_at, s.lat, s.lng, s.place_text, s.direction, s.note, s.photo_url,
       s.reporter_name, s.status, s.owner_note, (s.reporter_id is not null) as verified,
       left(md5('wm-poster:' || coalesce(s.reporter_id::text, 's:' || s.id::text)), 12) as poster,
       s.photos
from public.sightings s join public.cases c on c.id = s.case_id
where s.status = 'confirmed' and not c.hidden;
grant select on public.sightings_public to anon, authenticated;

drop trigger if exists sightings_guard_upd on public.sightings;
create trigger sightings_guard_upd before update of place_text, direction, note, reporter_name, reporter_contact, photo_url, photos
  on public.sightings for each row execute function public.ugc_guard_update();

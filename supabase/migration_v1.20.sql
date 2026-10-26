-- 汪喵回家 migration v1.20 — 飼主管理頁不再拿到回報者的會員編號
--   owner_sightings 原本回傳整列目擊資料（包含 reporter_id，也就是回報者的會員 uuid）。
--   飼主只需要知道「是不是會員回報」，改成回傳 verified（true/false）。
-- 可重複執行。

drop function if exists public.owner_sightings(uuid, text);
create function public.owner_sightings(p_id uuid, p_token text)
returns table (
  id uuid, case_id uuid, created_at timestamptz, seen_at timestamptz, lat double precision, lng double precision,
  place_text text, direction text, note text, photo_url text, reporter_name text, reporter_contact text,
  status text, owner_note text, notified boolean, verified boolean
)
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.can_manage_case(p_id, p_token) then raise exception '管理連結無效'; end if;
  return query
    select s.id, s.case_id, s.created_at, s.seen_at, s.lat, s.lng, s.place_text, s.direction, s.note, s.photo_url,
           s.reporter_name, s.reporter_contact, s.status, s.owner_note, s.notified, (s.reporter_id is not null)
      from public.sightings s where s.case_id = p_id order by s.seen_at desc;
end $$;
revoke all on function public.owner_sightings(uuid, text) from public;
grant execute on function public.owner_sightings(uuid, text) to anon, authenticated;

select 'WangMiao migration v1.20 installed' as result;

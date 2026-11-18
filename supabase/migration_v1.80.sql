-- v1.80 管理後台：看單一會員發佈過的內容（走失案件、拾獲通報、目擊、寵物、交朋友名片、聚會與聚會留言）
-- 私訊（chat）是會員之間的私人對話，不列在這裡
create or replace function public.admin_member_content(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare j jsonb;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  select jsonb_build_object(
    'cases', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select c.id, c.created_at, c.name, c.species, c.status, c.lost_city, c.lost_district, c.lost_place,
               left(coalesce(c.features,''), 200) as features, left(coalesce(c.notes,''), 300) as notes, c.photos[1] as photo
          from public.cases c where c.owner_id = p_uid order by c.created_at desc limit 50) x), '[]'),
    'founds', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select f.id, f.created_at, f.kind, f.status, f.city, f.district, f.place_text, f.breed, f.colour,
               left(coalesce(f.features,''), 200) as features, left(coalesce(f.notes,''), 300) as notes, f.photos[1] as photo
          from public.found_reports f where f.owner_id = p_uid order by f.created_at desc limit 50) x), '[]'),
    'sightings', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select s.id, s.created_at, s.seen_at, s.case_id, c.name as case_name, s.place_text, s.direction,
               left(coalesce(s.note,''), 300) as note, s.status, s.photo_url as photo
          from public.sightings s left join public.cases c on c.id = s.case_id
         where s.reporter_id = p_uid order by s.created_at desc limit 50) x), '[]'),
    'pets', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select t.id, t.created_at, t.name, t.species, t.breed, t.colour, t.photos[1] as photo
          from public.pets t where t.owner_id = p_uid order by t.created_at desc limit 50) x), '[]'),
    'cards', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select k.pet_id as id, k.created_at, k.name, k.species, k.breed, k.city, k.district, k.intro, k.tags, k.hidden, k.photo
          from public.pet_cards k where k.owner_id = p_uid order by k.created_at desc limit 50) x), '[]'),
    'meets', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select m.id, m.created_at, m.title, m.place, m.city, m.district, m.starts_at, m.note, m.hidden
          from public.pet_meets m where m.owner_id = p_uid order by m.created_at desc limit 50) x), '[]'),
    'meet_msgs', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select g.id, g.created_at, g.meet_id, m.title as meet_title, g.body
          from public.pet_meet_msgs g left join public.pet_meets m on m.id = g.meet_id
         where g.user_id = p_uid order by g.created_at desc limit 50) x), '[]')
  ) into j;
  return j;
end $$;
revoke all on function public.admin_member_content(uuid) from public, anon;
grant execute on function public.admin_member_content(uuid) to authenticated;

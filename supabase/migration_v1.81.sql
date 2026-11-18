-- v1.81 管理後台「網友發佈」：網站上網友發的走失案件、拾獲通報、目擊（不含管理員發的、不含農業部同步的）
create or replace function public.admin_site_posts(p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare j jsonb;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  with adm as (select id from public.profiles where coalesce(is_admin, false)),
  feed as (
    select 'case'::text as type, c.id, c.created_at, c.name as title, c.species, c.status, c.hidden,
           concat_ws(' ', c.lost_city, c.lost_district, c.lost_place) as area,
           left(concat_ws(E'\n', nullif(c.features,''), nullif(c.notes,'')), 400) as body,
           c.photos[1] as photo, null::uuid as case_id, c.owner_id as uid,
           c.contact_name as who, c.contact_phone as phone
      from public.cases c
     where c.source = 'site' and (c.owner_id is null or c.owner_id not in (select id from adm))
    union all
    select 'found', f.id, f.created_at, concat_ws('・', case when f.kind = 'found' then '撿到' else '看到' end, nullif(f.breed,''), nullif(f.colour,'')),
           null, f.status, f.hidden, concat_ws(' ', f.city, f.district, f.place_text),
           left(concat_ws(E'\n', nullif(f.features,''), nullif(f.notes,'')), 400), f.photos[1], null, f.owner_id,
           f.reporter_name, f.reporter_phone
      from public.found_reports f
     where f.owner_id is null or f.owner_id not in (select id from adm)
    union all
    select 'sighting', s.id, s.created_at, '目擊回報：' || coalesce(c.name, '案件'), null, s.status, false,
           concat_ws(' ', nullif(s.place_text,''), case when nullif(s.direction,'') is not null then '往' || s.direction end),
           left(coalesce(s.note,''), 400), s.photo_url, s.case_id, s.reporter_id,
           s.reporter_name, s.reporter_contact
      from public.sightings s left join public.cases c on c.id = s.case_id
     where s.reporter_id is null or s.reporter_id not in (select id from adm)
  )
  select coalesce(jsonb_agg(x order by x.created_at desc), '[]') into j from (
    select f.*, u.email as member_email, p.display_name
      from feed f left join auth.users u on u.id = f.uid left join public.profiles p on p.id = f.uid
     order by f.created_at desc offset greatest(p_offset, 0) limit 50) x;
  return j;
end $$;
revoke all on function public.admin_site_posts(int) from public, anon;
grant execute on function public.admin_site_posts(int) to authenticated;

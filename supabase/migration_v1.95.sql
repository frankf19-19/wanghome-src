-- 汪喵回家 migration v1.95 — 民眾送養：約好的見面時間出現在申請清單和「通知」（前一天、當天提醒）
--   可重複執行。
drop function if exists public.rehome_apps_for(uuid);
create or replace function public.rehome_apps_for(p_rehome uuid)
returns table(id uuid, applicant_id uuid, username text, avatar_url text, joined timestamptz,
              answers jsonb, intro text, contact_name text, contact_phone text, status text,
              id_checked boolean, owner_agree_at timestamptz, applicant_agree_at timestamptz,
              created_at timestamptz, updated_at timestamptz, apps_7d integer, reports integer, has_pets boolean, meet_at timestamptz, meet_place text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.rehomes r where r.id = p_rehome and r.owner_id = auth.uid()) then
    raise exception '只有送養人看得到申請';
  end if;
  return query
  select a.id, a.applicant_id, p.username, p.avatar_url, p.created_at,
         a.answers, a.intro, a.contact_name,
         case when a.status in ('meet','adopted') then a.contact_phone end,
         a.status, a.id_checked, a.owner_agree_at, a.applicant_agree_at, a.created_at, a.updated_at,
         (select count(*) from public.rehome_apps x where x.applicant_id = a.applicant_id and x.created_at > now() - interval '7 days')::int,
         (select count(*) from public.reports rp where rp.target_type = 'user' and rp.target_id = a.applicant_id)::int,
         exists (select 1 from public.pets pt where pt.owner_id = a.applicant_id), a.meet_at, a.meet_place
    from public.rehome_apps a join public.profiles p on p.id = a.applicant_id
   where a.rehome_id = p_rehome
   order by case a.status when 'meet' then 0 when 'talking' then 1 when 'pending' then 2 when 'adopted' then 3 else 4 end, a.created_at desc;
end $$;
drop function if exists public.rehome_my_apps();
create or replace function public.rehome_my_apps()
returns table(id uuid, rehome_id uuid, status text, created_at timestamptz, updated_at timestamptz,
              pet_name text, pet_species text, pet_photo text, city text, district text, owner_username text, rehome_status text, meet_at timestamptz, meet_place text)
language sql stable security definer set search_path = public as $$
  select a.id, a.rehome_id, a.status, a.created_at, a.updated_at, r.name, r.species, r.photos[1], r.city, r.district, p.username, r.status, a.meet_at, a.meet_place
    from public.rehome_apps a join public.rehomes r on r.id = a.rehome_id left join public.profiles p on p.id = r.owner_id
   where a.applicant_id = auth.uid()
   order by a.updated_at desc limit 100;
$$;
create or replace function public.rehome_meets()
returns table(app_id uuid, role text, pet_name text, pet_photo text, other_name text, meet_at timestamptz, meet_place text)
language sql stable security definer set search_path = public as $$
  select a.id, case when r.owner_id = auth.uid() then 'owner' else 'applicant' end, r.name, r.photos[1],
         case when r.owner_id = auth.uid() then a.contact_name else r.contact_name end, a.meet_at, a.meet_place
    from public.rehome_apps a join public.rehomes r on r.id = a.rehome_id
   where a.status = 'meet' and a.meet_at between now() - interval '6 hours' and now() + interval '2 days'
     and (a.applicant_id = auth.uid() or r.owner_id = auth.uid())
   order by a.meet_at limit 20;
$$;
revoke all on function public.rehome_apps_for(uuid), public.rehome_my_apps(), public.rehome_meets() from public, anon;
grant execute on function public.rehome_apps_for(uuid), public.rehome_my_apps(), public.rehome_meets() to authenticated;

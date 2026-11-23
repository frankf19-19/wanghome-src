-- 汪喵回家 migration v1.93 — 民眾送養：領養人同意的話，「找到家之後」的近況照片可以公開在刊登頁（給還在猶豫的人看）
--   預設不公開；只有領養人自己能打開或關掉。
--   可重複執行。
alter table public.rehome_apps add column if not exists share_updates boolean not null default false;

create or replace function public.rehome_share_set(p_app uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.rehome_apps set share_updates = coalesce(p_on, false)
   where id = p_app and applicant_id = auth.uid() and status = 'adopted';
  if not found then raise exception '找不到這份領養紀錄'; end if;
end $$;
revoke all on function public.rehome_share_set(uuid, boolean) from public, anon;
grant execute on function public.rehome_share_set(uuid, boolean) to authenticated;

-- 公開的「找到家之後」：只回傳照片、文字、日期，不回傳領養人的任何資料
create or replace function public.rehome_public_updates(p_rehome uuid)
returns table(photo text, note text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select u.photo, u.note, u.created_at
    from public.rehomes r
    join public.rehome_apps a on a.id = r.adopter_app and a.status = 'adopted' and a.share_updates
    join public.rehome_updates u on u.app_id = a.id
   where r.id = p_rehome and r.status = 'adopted' and not r.hidden
   order by u.created_at desc limit 12;
$$;
grant execute on function public.rehome_public_updates(uuid) to anon, authenticated;

-- rehome_followups 多回傳 share_updates
drop function if exists public.rehome_followups();
create function public.rehome_followups()
returns table(app_id uuid, rehome_id uuid, role text, pet_name text, pet_photo text, other_name text,
              adopted_at timestamptz, req_followup boolean, last_update timestamptz, last_photo text, updates integer, share_updates boolean)
language sql stable security definer set search_path = public as $$
  select a.id, r.id, case when r.owner_id = auth.uid() then 'owner' else 'adopter' end, r.name, r.photos[1],
         case when r.owner_id = auth.uid() then a.contact_name else r.contact_name end,
         r.adopted_at, r.req_followup,
         (select max(u.created_at) from public.rehome_updates u where u.app_id = a.id),
         (select u.photo from public.rehome_updates u where u.app_id = a.id and u.photo is not null order by u.created_at desc limit 1),
         (select count(*)::int from public.rehome_updates u where u.app_id = a.id),
         a.share_updates
    from public.rehome_apps a join public.rehomes r on r.id = a.rehome_id
   where a.status = 'adopted' and r.adopted_at > now() - interval '400 days'
     and (a.applicant_id = auth.uid() or r.owner_id = auth.uid())
   order by r.adopted_at desc limit 50;
$$;
revoke all on function public.rehome_followups() from public, anon;
grant execute on function public.rehome_followups() to authenticated;

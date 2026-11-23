-- 汪喵回家 migration v1.94 — 民眾送養：婉拒時可以留一句話、約好的見面時間地點記在申請頁
--   可重複執行。
alter table public.rehome_apps add column if not exists decline_note text check (char_length(coalesce(decline_note,'')) <= 200);
alter table public.rehome_apps add column if not exists meet_at timestamptz;
alter table public.rehome_apps add column if not exists meet_place text check (char_length(coalesce(meet_place,'')) <= 60);

-- 婉拒留言（送養人）
create or replace function public.rehome_decline_note(p_app uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.rehome_text_ok(p_note) or not public.rehome_contact_free(p_note) then raise exception '留言請不要放聯絡方式或買賣相關內容'; end if;
  update public.rehome_apps a set decline_note = nullif(btrim(left(p_note, 200)), '')
    from public.rehomes r
   where a.id = p_app and r.id = a.rehome_id and r.owner_id = auth.uid() and a.status = 'declined';
  if not found then raise exception '找不到這份申請'; end if;
end $$;

-- 約見面時間地點（雙方都可以填；同意見面之後才可以）
create or replace function public.rehome_meet_set(p_app uuid, p_at timestamptz, p_place text) returns void
language plpgsql security definer set search_path = public as $$
declare a public.rehome_apps; r public.rehomes;
begin
  select * into a from public.rehome_apps where id = p_app;
  if a.id is null then raise exception '找不到這份申請'; end if;
  select * into r from public.rehomes where id = a.rehome_id;
  if auth.uid() is distinct from r.owner_id and auth.uid() is distinct from a.applicant_id then raise exception '找不到這份申請'; end if;
  if a.status <> 'meet' then raise exception '同意見面之後才能約時間'; end if;
  if p_at is not null and (p_at < now() - interval '1 day' or p_at > now() + interval '90 days') then raise exception '請選 90 天內的時間'; end if;
  if coalesce(p_place,'') ~ '[0-9０-９]+\s*(號(?!\s*(出口|門|口|月台|碼頭|公園|倉庫)))' then raise exception '第一次見面請約公開場所，不要填住家地址'; end if;
  if not public.rehome_contact_free(p_place) then raise exception '地點請不要放聯絡方式'; end if;
  update public.rehome_apps set meet_at = p_at, meet_place = nullif(btrim(p_place), ''), updated_at = now() where id = p_app;
end $$;

revoke all on function public.rehome_decline_note(uuid, text), public.rehome_meet_set(uuid, timestamptz, text) from public, anon;
grant execute on function public.rehome_decline_note(uuid, text), public.rehome_meet_set(uuid, timestamptz, text) to authenticated;

drop function if exists public.rehome_app_get(uuid);
create or replace function public.rehome_app_get(p_app uuid)
returns table(id uuid, rehome_id uuid, my_role text, status text, answers jsonb, intro text,
              applicant_name text, applicant_phone text, applicant_username text,
              owner_name text, owner_phone text, owner_username text,
              pet_name text, pet_species text, pet_sex text, pet_photo text, pet_chip text, pet_neutered text,
              req_contract boolean, req_visit boolean, req_followup boolean, fee integer, fee_note text,
              id_checked boolean, owner_agree_at timestamptz, applicant_agree_at timestamptz,
              created_at timestamptz, updated_at timestamptz,
              decline_note text, meet_at timestamptz, meet_place text)
language sql stable security definer set search_path = public as $$
  select a.id, a.rehome_id, case when r.owner_id = auth.uid() then 'owner' else 'applicant' end, a.status, a.answers, a.intro,
         a.contact_name, case when a.status in ('meet','adopted') then a.contact_phone end, pa.username,
         r.contact_name, case when a.status in ('meet','adopted') then r.contact_phone end, po.username,
         r.name, r.species, r.sex, r.photos[1], r.chip, r.neutered,
         r.req_contract, r.req_visit, r.req_followup, r.fee, r.fee_note,
         a.id_checked, a.owner_agree_at, a.applicant_agree_at, a.created_at, a.updated_at,
         a.decline_note, a.meet_at, a.meet_place
    from public.rehome_apps a
    join public.rehomes r on r.id = a.rehome_id
    left join public.profiles pa on pa.id = a.applicant_id
    left join public.profiles po on po.id = r.owner_id
   where a.id = p_app and (r.owner_id = auth.uid() or a.applicant_id = auth.uid());
$$;
revoke all on function public.rehome_app_get(uuid) from public, anon;
grant execute on function public.rehome_app_get(uuid) to authenticated;

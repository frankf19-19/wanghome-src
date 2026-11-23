-- 汪喵回家 migration v1.88 — 民眾送養區（第二期）
--   1. 接回家之後的近況回報：領養人上傳照片＋幾句話，送養人看得到（隔天、一週、一個月，之後每三個月，一年）
--   2. 送養推播：新申請、狀態改變、切結書、近況回報（notify-message 用 pushed 欄位避免重複推）
--   可重複執行。

alter table public.rehome_apps add column if not exists pushed jsonb not null default '{}'::jsonb;

create table if not exists public.rehome_updates (
  id         uuid primary key default gen_random_uuid(),
  app_id     uuid not null references public.rehome_apps(id) on delete cascade,
  author_id  uuid not null references auth.users(id) on delete cascade,
  photo      text check (photo is null or photo ~ '^https://nopyhfpaykkiieudvoko\.supabase\.co/storage/v1/object/public/photos/cases/[^\s''"<>]+$'),
  note       text check (char_length(coalesce(note,'')) <= 500),
  created_at timestamptz not null default now(),
  check (photo is not null or coalesce(btrim(note),'') <> '')
);
create index if not exists rehome_updates_app_idx on public.rehome_updates(app_id, created_at desc);
alter table public.rehome_updates enable row level security;
revoke all on public.rehome_updates from anon, authenticated;

-- 領養人回報近況（完成送養之後才可以）
create or replace function public.rehome_update_add(p_app uuid, p_note text, p_photo text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); a public.rehome_apps; uid uuid;
begin
  if me is null then raise exception '請先登入'; end if;
  select * into a from public.rehome_apps where id = p_app;
  if a.id is null or a.applicant_id <> me then raise exception '找不到這份領養紀錄'; end if;
  if a.status <> 'adopted' then raise exception '完成送養之後才能回報近況'; end if;
  if p_photo is null and coalesce(btrim(p_note), '') = '' then raise exception '請放一張照片或寫幾句話'; end if;
  if (select count(*) from public.rehome_updates where author_id = me and created_at > now() - interval '1 day') >= 10 then
    raise exception '今天回報很多次了，明天再傳吧';
  end if;
  insert into public.rehome_updates(app_id, author_id, photo, note) values (p_app, me, p_photo, nullif(btrim(p_note), ''))
    returning id into uid;
  return uid;
end $$;

-- 一份領養的近況（送養人和領養人都看得到）
create or replace function public.rehome_updates_get(p_app uuid)
returns table(id uuid, photo text, note text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select u.id, u.photo, u.note, u.created_at from public.rehome_updates u
    join public.rehome_apps a on a.id = u.app_id join public.rehomes r on r.id = a.rehome_id
   where u.app_id = p_app and (a.applicant_id = auth.uid() or r.owner_id = auth.uid())
   order by u.created_at desc limit 100;
$$;

-- 我參與的、已完成的送養（給「通知」算該回報了沒、送養人看最新近況）
create or replace function public.rehome_followups()
returns table(app_id uuid, rehome_id uuid, role text, pet_name text, pet_photo text, other_name text,
              adopted_at timestamptz, req_followup boolean, last_update timestamptz, last_photo text, updates integer)
language sql stable security definer set search_path = public as $$
  select a.id, r.id, case when r.owner_id = auth.uid() then 'owner' else 'adopter' end, r.name, r.photos[1],
         case when r.owner_id = auth.uid() then a.contact_name else r.contact_name end,
         r.adopted_at, r.req_followup,
         (select max(u.created_at) from public.rehome_updates u where u.app_id = a.id),
         (select u.photo from public.rehome_updates u where u.app_id = a.id and u.photo is not null order by u.created_at desc limit 1),
         (select count(*)::int from public.rehome_updates u where u.app_id = a.id)
    from public.rehome_apps a join public.rehomes r on r.id = a.rehome_id
   where a.status = 'adopted' and r.adopted_at > now() - interval '400 days'
     and (a.applicant_id = auth.uid() or r.owner_id = auth.uid())
   order by r.adopted_at desc limit 50;
$$;

revoke all on function public.rehome_update_add(uuid, text, text), public.rehome_updates_get(uuid), public.rehome_followups() from public, anon;
grant execute on function public.rehome_update_add(uuid, text, text), public.rehome_updates_get(uuid), public.rehome_followups() to authenticated;

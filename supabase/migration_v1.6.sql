-- ============================================================
-- 汪喵回家 — 資料庫升級 v1.6：毛孩健康紀錄
--   1. pet_records：回診、疫苗、驅蟲、用藥、手術、體重、美容…（只有本人看得到）
--   2. 私密照片空間 pet-private（收據、病歷），路徑第一層必須是自己的 user id
--   3. due_targets()：給 daily.py 寄「下次到期」提醒
-- 可重複執行，不刪資料。
-- ============================================================

create table if not exists public.pet_records (
  id          uuid primary key default gen_random_uuid(),
  pet_id      uuid not null references public.pets(id) on delete cascade,
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  kind        text not null check (kind in ('vet','vaccine','deworm','med','surgery','weight','grooming','other')),
  date        date not null default current_date,
  title       text not null,
  clinic      text,
  weight_kg   numeric(5,2) check (weight_kg is null or (weight_kg > 0 and weight_kg < 200)),
  cost        integer check (cost is null or (cost >= 0 and cost < 10000000)),
  notes       text,
  next_due    date,
  done        boolean not null default false,    -- 「下次到期」已完成（例如已打完下一劑）
  files       text[] not null default '{}',      -- 私密空間的路徑（不是網址）
  constraint pet_records_len check (
    char_length(title) between 1 and 60 and
    char_length(coalesce(clinic,'')) <= 60 and
    char_length(coalesce(notes,'')) <= 2000 and
    coalesce(array_length(files,1),0) <= 6
  )
);
create index if not exists pet_records_pet_idx on public.pet_records(pet_id, date desc);
create index if not exists pet_records_due_idx on public.pet_records(owner_id, next_due) where next_due is not null and not done;
alter table public.pet_records enable row level security;
drop policy if exists "own pet records" on public.pet_records;
create policy "own pet records" on public.pet_records for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
grant select, insert, update, delete on public.pet_records to authenticated;

-- 建立時：強制 owner = 本人，且寵物必須是自己的；每隻寵物最多 1000 筆
create or replace function public.check_pet_record() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.owner_id := auth.uid();
  if not exists (select 1 from public.pets where id = new.pet_id and owner_id = auth.uid()) then
    raise exception '找不到這隻寵物';
  end if;
  if tg_op = 'INSERT' and (select count(*) from public.pet_records where pet_id = new.pet_id) >= 1000 then
    raise exception '紀錄已達上限';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists pet_records_check on public.pet_records;
create trigger pet_records_check before insert or update on public.pet_records
  for each row execute function public.check_pet_record();

-- 私密照片空間
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pet-private', 'pet-private', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "own private read"   on storage.objects;
drop policy if exists "own private upload" on storage.objects;
drop policy if exists "own private delete" on storage.objects;
create policy "own private read" on storage.objects for select to authenticated
  using (bucket_id = 'pet-private' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own private upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'pet-private' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own private delete" on storage.objects for delete to authenticated
  using (bucket_id = 'pet-private' and (storage.foldername(name))[1] = auth.uid()::text);

-- 到期提醒（7 天內到期、尚未完成、尚未寄過）
create or replace function public.due_targets()
returns table(user_id uuid, email text, record_id uuid, pet_name text, title text, next_due date)
language sql stable security definer set search_path = public, auth as $$
  select r.owner_id, u.email::text, r.id, p.name, r.title, r.next_due
  from public.pet_records r
  join public.pets p on p.id = r.pet_id
  join auth.users u on u.id = r.owner_id
  where r.next_due is not null and not r.done
    and r.next_due <= current_date + 7 and r.next_due >= current_date - 30
    and u.email is not null
    and not exists (select 1 from public.notify_log l where l.user_id = r.owner_id and l.kind = 'due' and l.ref_id = r.id);
$$;
revoke all on function public.due_targets() from public, anon, authenticated;
grant execute on function public.due_targets() to service_role;

grant all on public.pet_records to service_role;
grant all on all functions in schema public to service_role;

select 'WangMiao migration v1.6 installed' as result;

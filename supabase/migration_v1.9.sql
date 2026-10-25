-- ============================================================
-- 汪喵回家 — 資料庫升級 v1.9：藥品與保養品
--   pet_meds：正在吃的藥品／保養品（名稱、劑量、頻率、時段、期間、用途）
--   pet_med_logs：每次給藥紀錄（今天吃了沒）
--   只有本人看得到。可重複執行，不刪資料。
-- ============================================================
create table if not exists public.pet_meds (
  id          uuid primary key default gen_random_uuid(),
  pet_id      uuid not null references public.pets(id) on delete cascade,
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  kind        text not null default 'med' check (kind in ('med','supplement')),
  name        text not null,
  dose_amount numeric(8,2) check (dose_amount is null or (dose_amount > 0 and dose_amount < 100000)),
  dose_unit   text,
  freq        text not null default 'daily1' check (freq in ('daily1','daily2','daily3','every_other','weekly','asneeded','other')),
  times       text[] not null default '{}',
  start_date  date not null default current_date,
  end_date    date,
  purpose     text,
  clinic      text,
  notes       text,
  active      boolean not null default true,
  constraint pet_meds_len check (
    char_length(name) between 1 and 60 and
    char_length(coalesce(dose_unit,'')) <= 10 and
    char_length(coalesce(purpose,'')) <= 100 and
    char_length(coalesce(clinic,'')) <= 60 and
    char_length(coalesce(notes,'')) <= 500 and
    coalesce(array_length(times,1),0) <= 6 and
    (end_date is null or end_date >= start_date)
  )
);
create index if not exists pet_meds_pet_idx on public.pet_meds(pet_id, active);
create index if not exists pet_meds_owner_idx on public.pet_meds(owner_id, active);
alter table public.pet_meds enable row level security;
drop policy if exists "own pet meds" on public.pet_meds;
create policy "own pet meds" on public.pet_meds for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
grant select, insert, update, delete on public.pet_meds to authenticated;

create or replace function public.check_pet_med() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.owner_id := auth.uid();
  if not exists (select 1 from public.pets where id = new.pet_id and owner_id = auth.uid()) then
    raise exception '找不到這隻寵物';
  end if;
  if tg_op = 'INSERT' and (select count(*) from public.pet_meds where pet_id = new.pet_id) >= 200 then
    raise exception '藥品／保養品已達上限';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists pet_meds_check on public.pet_meds;
create trigger pet_meds_check before insert or update on public.pet_meds
  for each row execute function public.check_pet_med();

create table if not exists public.pet_med_logs (
  id        uuid primary key default gen_random_uuid(),
  med_id    uuid not null references public.pet_meds(id) on delete cascade,
  owner_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  given_at  timestamptz not null default now(),
  slot      text,
  constraint pet_med_logs_len check (char_length(coalesce(slot,'')) <= 10)
);
create index if not exists pet_med_logs_med_idx on public.pet_med_logs(med_id, given_at desc);
alter table public.pet_med_logs enable row level security;
drop policy if exists "own med logs" on public.pet_med_logs;
create policy "own med logs" on public.pet_med_logs for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
grant select, insert, delete on public.pet_med_logs to authenticated;

create or replace function public.check_pet_med_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.owner_id := auth.uid();
  if not exists (select 1 from public.pet_meds where id = new.med_id and owner_id = auth.uid()) then
    raise exception '找不到這筆藥品';
  end if;
  if (select count(*) from public.pet_med_logs where med_id = new.med_id and given_at > now() - interval '1 day') >= 50 then
    raise exception '紀錄太頻繁';
  end if;
  return new;
end $$;
drop trigger if exists pet_med_logs_check on public.pet_med_logs;
create trigger pet_med_logs_check before insert on public.pet_med_logs
  for each row execute function public.check_pet_med_log();

grant all on public.pet_meds, public.pet_med_logs to service_role;

select 'WangMiao migration v1.9 installed' as result;

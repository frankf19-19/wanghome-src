-- 汪喵回家 migration v1.101 — 動物醫院專區：刪除帳號不會被病歷卡住
--   醫院帳號的會員刪除帳號時：醫院資料和已開的病歷保留（病歷要留存），只解除和帳號的連結並停權
alter table public.clinics alter column owner_id drop not null;
alter table public.clinics drop constraint if exists clinics_owner_id_fkey;
alter table public.clinics add constraint clinics_owner_id_fkey foreign key (owner_id) references auth.users(id) on delete set null;
alter table public.clinic_visits alter column created_by drop not null;
alter table public.clinic_visits drop constraint if exists clinic_visits_created_by_fkey;
alter table public.clinic_visits add constraint clinic_visits_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null;

-- 醫院負責人的帳號刪掉了：醫院自動停權
create or replace function public.clinics_orphan() returns trigger language plpgsql as $$
begin
  if new.owner_id is null and old.owner_id is not null then new.status := 'suspended'; new.review_note := '負責人已刪除帳號'; end if;
  return new;
end $$;
drop trigger if exists clinics_orphan on public.clinics;
create trigger clinics_orphan before update on public.clinics for each row execute function public.clinics_orphan();

-- 病歷鎖定的觸發器：帳號刪除造成 created_by 變成空的，要允許
create or replace function public.clinic_visits_lock() returns trigger language plpgsql as $$
begin
  if new.pet_id is distinct from old.pet_id and new.pet_id is not null then raise exception '病歷的毛孩不能更改'; end if;
  if new.clinic_id is distinct from old.clinic_id or new.created_at is distinct from old.created_at
     or (new.created_by is distinct from old.created_by and new.created_by is not null) then
    raise exception '病歷的醫院不能更改';
  end if;
  new.updated_at := now();
  return new;
end $$;

select 'WangMiao migration v1.101 installed' as result;

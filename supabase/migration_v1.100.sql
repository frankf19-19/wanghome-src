-- 汪喵回家 migration v1.100 — 動物醫院專區安全性補強
--   醫院修改病歷時不能把病歷改到別的毛孩、別的醫院名下（避免假病歷出現在其他飼主的健康手冊）
drop policy if exists cv_clinic_update on public.clinic_visits;
create policy cv_clinic_update on public.clinic_visits for update to authenticated
  using (clinic_id = public.my_clinic_id())
  with check (clinic_id = public.my_clinic_id());

create or replace function public.clinic_visits_lock() returns trigger language plpgsql as $$
begin
  if new.pet_id is distinct from old.pet_id or new.clinic_id is distinct from old.clinic_id or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception '病歷的毛孩、醫院不能更改';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists clinic_visits_lock on public.clinic_visits;
create trigger clinic_visits_lock before update on public.clinic_visits for each row execute function public.clinic_visits_lock();

select 'WangMiao migration v1.100 installed' as result;

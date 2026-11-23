-- 汪喵回家 migration v1.91 — 民眾送養：送養人把刊登「下架」時，還在進行中的申請自動婉拒（不讓申請人一直等）
--   可重複執行。
create or replace function public.rehomes_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'closed' and old.status <> 'closed' then
    update public.rehome_apps set status = 'declined', updated_at = now()
     where rehome_id = new.id and status in ('pending','talking','meet');
  end if;
  return null;
end $$;
drop trigger if exists rehomes_after on public.rehomes;
create trigger rehomes_after after update of status on public.rehomes for each row execute function public.rehomes_after();

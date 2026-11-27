-- 汪喵回家 migration v1.131 — 散步日記防灌水：同一隻毛孩、同一天最多記 4 次散步、合計最多 720 分鐘。可重複執行。
create or replace function public.pet_walks_day_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare n int; mins int;
begin
  select count(*), coalesce(sum(coalesce(minutes, 0)), 0) into n, mins from public.pet_walks
   where pet_id = new.pet_id and walked_on = new.walked_on and id <> new.id;
  if n >= 4 then raise exception 'walk_day_limit' using hint = '同一天最多記 4 次散步'; end if;
  if mins + coalesce(new.minutes, 0) > 720 then raise exception 'walk_day_minutes' using hint = '同一天合計最多 720 分鐘'; end if;
  return new;
end $$;
drop trigger if exists pet_walks_day_guard on public.pet_walks;
create trigger pet_walks_day_guard before insert or update of walked_on, minutes, pet_id on public.pet_walks
  for each row execute function public.pet_walks_day_guard();
select 'pet_walks_day_guard installed' as result;

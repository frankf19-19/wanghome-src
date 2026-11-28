-- 汪喵回家 migration v1.134 — 散步冒險好友排行：walk_board 多回傳 today（這隻毛孩今天有沒有散步）。可重複執行。
drop function if exists public.walk_board();
create or replace function public.walk_board()
returns table (pet_id uuid, name text, species text, breed text, colour text, art text, owner_name text, mine boolean, km numeric, days int, minutes int, today boolean)
language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as uid),
  wk as (select (date_trunc('week', now() at time zone 'Asia/Taipei'))::date as d0),
  people as (
    select uid from me where uid is not null
    union
    select case when f.a = me.uid then f.b else f.a end from public.friends f, me
     where f.status = 'accepted' and me.uid in (f.a, f.b)
  ),
  agg as (
    select w.pet_id, round(coalesce(sum(least(coalesce(w.km, 0), 60)), 0), 1) as km, count(distinct w.walked_on)::int as days, coalesce(sum(w.minutes), 0)::int as minutes
      from public.pet_walks w, wk where w.walked_on >= wk.d0 and w.walked_on < wk.d0 + 7 group by w.pet_id
  )
  select p.id, p.name, p.species, p.breed, p.colour, p.art,
         coalesce(nullif(pr.display_name, ''), '會員'), p.owner_id = (select uid from me),
         coalesce(a.km, 0), coalesce(a.days, 0), coalesce(a.minutes, 0),
         exists (select 1 from public.pet_walks t where t.pet_id = p.id and t.walked_on = (now() at time zone 'Asia/Taipei')::date)
    from public.pets p join people pe on pe.uid = p.owner_id
    left join agg a on a.pet_id = p.id
    left join public.profiles pr on pr.id = p.owner_id
   where a.pet_id is not null or p.owner_id = (select uid from me)
   order by coalesce(a.km, 0) desc, coalesce(a.days, 0) desc, coalesce(a.minutes, 0) desc
   limit 50
$$;
revoke all on function public.walk_board() from public, anon;
grant execute on function public.walk_board() to authenticated;
select 'walk_board v1.134 installed' as result;

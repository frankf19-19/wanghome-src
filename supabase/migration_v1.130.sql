-- 汪喵回家 migration v1.130 — 散步冒險防作弊：打怪經驗每天最多 3000、賣寶物每天最多換 2000 金幣；
--   散步日記的寶物每一筆最多 60 個（跟 App 的背包上限一樣）。其他規則跟 v1.129 一樣。可重複執行。
create or replace function public.walk_game(p_pet uuid, p_act text, p_arg jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g public.pet_game;
  d text := ((now() at time zone 'Asia/Taipei')::date)::text;
  gear_t jsonb := '{"rope":["weapon",30],"squeak":["weapon",90],"club":["weapon",250],"wand":["weapon",600],"col1":["collar",30],"col2":["collar",90],"col3":["collar",250],"col4":["collar",600],"scarf":["outfit",40],"rain":["outfit",120],"cape":["outfit",320],"armor":["outfit",750]}';
  sell_t jsonb := '{"bone":2,"ball":5,"frisbee":9,"toy":14,"stick":18,"star":40,"gift":30}';
  m jsonb; st jsonb; it text; slot text; pr int; lv int; c int := 0; x int := 0; n int; k text; bag int;
  cap int; ok boolean := true; why text := null; nowe numeric := extract(epoch from now());
begin
  if auth.uid() is null or not exists (select 1 from public.pets where id = p_pet and owner_id = auth.uid()) then
    raise exception 'not_owner';
  end if;
  insert into public.pet_game (pet_id) values (p_pet) on conflict (pet_id) do nothing;
  select * into g from public.pet_game where pet_id = p_pet for update;
  m := coalesce(g.meta, '{}'::jsonb);
  if coalesce(m->>'d', '') <> d then m := m || jsonb_build_object('d', d, 'earn', 0, 'fights', 0, 'km', 0, 'xpd', 0, 'sell', 0); end if;
  st := case when coalesce(m->'st'->>'d', '') = d then m->'st' else jsonb_build_object('d', d, 'ids', '[]'::jsonb) end;
  cap := case when extract(isodow from (now() at time zone 'Asia/Taipei')) in (6, 7) then 3000 else 1500 end;
  it := p_arg->>'item';

  if p_act in ('buy', 'up', 'equip', 'sellgear') then
    if it is null or not gear_t ? it then raise exception 'bad_item'; end if;
    slot := gear_t->it->>0; pr := (gear_t->it->>1)::int; lv := coalesce((g.gear->>it)::int, -1);
  end if;

  if p_act = 'buy' then
    if lv >= 0 then ok := false; why := 'owned';
    elsif g.coins < pr then ok := false; why := 'coins';
    else g.coins := g.coins - pr; g.gear := g.gear || jsonb_build_object(it, 0);
      if not g.eq ? slot then g.eq := g.eq || jsonb_build_object(slot, it); end if; end if;

  elsif p_act = 'up' then
    select coalesce(sum(coalesce((loot->>'bone')::int, 0)), 0) into bag from public.pet_walks where pet_id = p_pet;
    bag := bag - coalesce((g.sold->>'bone')::int, 0);
    c := round(pr * 0.4 * (lv + 1)); n := (lv + 1) * 2;
    if lv < 0 then ok := false; why := 'not_owned';
    elsif lv >= 5 then ok := false; why := 'max';
    elsif g.coins < c then ok := false; why := 'coins';
    elsif bag < n then ok := false; why := 'bones';
    else g.coins := g.coins - c; g.sold := g.sold || jsonb_build_object('bone', coalesce((g.sold->>'bone')::int, 0) + n);
      g.gear := g.gear || jsonb_build_object(it, lv + 1); end if;

  elsif p_act = 'equip' then
    if lv < 0 then ok := false; why := 'not_owned';
    elsif g.eq->>slot = it then g.eq := g.eq - slot;
    else g.eq := g.eq || jsonb_build_object(slot, it); end if;

  elsif p_act = 'sellgear' then
    if lv < 0 then ok := false; why := 'not_owned';
    else g.coins := g.coins + pr / 2; g.gear := g.gear - it; if g.eq->>slot = it then g.eq := g.eq - slot; end if; end if;

  elsif p_act = 'sellloot' then
    k := p_arg->>'k'; n := least(greatest(coalesce((p_arg->>'n')::int, 0), 0), 999);
    if k is null or not sell_t ? k or n < 1 then raise exception 'bad_item'; end if;
    select coalesce(sum(coalesce((loot->>k)::int, 0)), 0) into bag from public.pet_walks where pet_id = p_pet;
    bag := bag - coalesce((g.sold->>k)::int, 0);
    pr := (sell_t->>k)::int;
    if bag < n then ok := false; why := 'not_enough';
    else
      n := least(n, greatest(2000 - coalesce((m->>'sell')::int, 0), 0) / pr);
      if n < 1 then ok := false; why := 'cap';
      else g.sold := g.sold || jsonb_build_object(k, coalesce((g.sold->>k)::int, 0) + n); g.coins := g.coins + n * pr;
        m := m || jsonb_build_object('sell', coalesce((m->>'sell')::int, 0) + n * pr); end if;
    end if;

  elsif p_act = 'fight' then
    c := least(greatest(coalesce((p_arg->>'coins')::int, 0), 0), 150);
    x := least(greatest(coalesce((p_arg->>'xp')::int, 0), 0), 200);
    k := p_arg->>'mon';
    if k is null or k !~ '^[a-z]{2,10}$' then raise exception 'bad_mon'; end if;
    if nowe - coalesce((m->>'lastf')::numeric, 0) < 8 then ok := false; why := 'too_fast';
    elsif coalesce((m->>'fights')::int, 0) >= 100 then ok := false; why := 'cap';
    else
      c := least(c, greatest(cap - coalesce((m->>'earn')::int, 0), 0));
      x := least(x, greatest(3000 - coalesce((m->>'xpd')::int, 0), 0));
      g.coins := g.coins + c; g.bxp := g.bxp + x;
      g.kills := g.kills || jsonb_build_object(k, coalesce((g.kills->>k)::int, 0) + 1);
      m := m || jsonb_build_object('fights', coalesce((m->>'fights')::int, 0) + 1, 'earn', coalesce((m->>'earn')::int, 0) + c, 'xpd', coalesce((m->>'xpd')::int, 0) + x, 'lastf', round(nowe));
    end if;

  elsif p_act = 'station' then
    k := p_arg->>'st'; c := least(greatest(coalesce((p_arg->>'coins')::int, 0), 0), 80);
    if k is null or k !~ '^[nwr][0-9]{1,12}$' then raise exception 'bad_station'; end if;
    if (st->'ids') ? k then ok := false; why := 'used';
    elsif jsonb_array_length(st->'ids') >= 12 then ok := false; why := 'cap';
    else c := least(c, greatest(cap - coalesce((m->>'earn')::int, 0), 0));
      g.coins := g.coins + c; st := jsonb_set(st, '{ids}', (st->'ids') || to_jsonb(k));
      m := m || jsonb_build_object('earn', coalesce((m->>'earn')::int, 0) + c); end if;

  elsif p_act = 'km' then
    c := least(greatest(coalesce((p_arg->>'coins')::int, 0), 0), 60);
    if coalesce((m->>'km')::int, 0) >= 60 then ok := false; why := 'cap';
    else c := least(c, greatest(cap - coalesce((m->>'earn')::int, 0), 0));
      g.coins := g.coins + c; m := m || jsonb_build_object('km', coalesce((m->>'km')::int, 0) + 1, 'earn', coalesce((m->>'earn')::int, 0) + c); end if;

  elsif p_act = 'quest' then
    if m->>'qd' = d then ok := false; why := 'used';
    else g.coins := g.coins + 30; m := m || jsonb_build_object('qd', d); end if;

  elsif p_act <> 'get' then
    raise exception 'bad_act';
  end if;

  m := m || jsonb_build_object('st', st);
  update public.pet_game set coins = g.coins, bxp = g.bxp, gear = g.gear, eq = g.eq, sold = g.sold, kills = g.kills, meta = m, updated_at = now()
   where pet_id = p_pet;
  return jsonb_build_object('ok', ok, 'why', why, 'coins', g.coins, 'bxp', g.bxp, 'gear', g.gear, 'eq', g.eq, 'sold', g.sold, 'kills', g.kills, 'meta', m);
end $$;
revoke all on function public.walk_game(uuid, text, jsonb) from public, anon;
grant execute on function public.walk_game(uuid, text, jsonb) to authenticated;

-- 玩家只能讀自己的存檔，不能直接改
revoke insert, update, delete on public.pet_game from authenticated;
drop policy if exists "own pet game" on public.pet_game;
drop policy if exists "own pet game read" on public.pet_game;
create policy "own pet game read" on public.pet_game for select to authenticated
  using (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));
-- 每次散步最多 40 個寶物
alter table public.pet_walks drop constraint if exists pet_walks_loot_n_chk;
select count(*) as pet_game_rows from public.pet_game;

-- 散步日記的寶物：每一種 0～60 個、合計最多 60 個
create or replace function public.walk_loot_ok(l jsonb) returns boolean language sql immutable as $$
  select l is null or (jsonb_typeof(l) = 'object' and not exists (
    select 1 from jsonb_each(l) e where jsonb_typeof(e.value) <> 'number' or (e.value)::text !~ '^[0-9]+$' or (e.value)::int > 60)
    and coalesce((select sum((e.value)::int) from jsonb_each(l) e where jsonb_typeof(e.value) = 'number' and (e.value)::text ~ '^[0-9]+$'), 0) <= 60)
$$;
alter table public.pet_walks drop constraint if exists pet_walks_loot_n_chk;
alter table public.pet_walks add constraint pet_walks_loot_n_chk check (public.walk_loot_ok(loot)) not valid;
select 'walk_game v1.130 installed' as result;

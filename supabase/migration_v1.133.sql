-- 汪喵回家 migration v1.133 — 散步冒險：商店新增傳說級裝備（黃金骨頭劍 1500、傳說鈴鐺項圈 1500、國王披風 1800）。其他規則跟 v1.132 一樣。可重複執行。
create or replace function public.walk_game(p_pet uuid, p_act text, p_arg jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g public.pet_game;
  d text := ((now() at time zone 'Asia/Taipei')::date)::text;
  gear_t jsonb := '{"rope":["weapon",30],"squeak":["weapon",90],"club":["weapon",250],"wand":["weapon",600],"col1":["collar",30],"col2":["collar",90],"col3":["collar",250],"col4":["collar",600],"scarf":["outfit",40],"rain":["outfit",120],"cape":["outfit",320],"armor":["outfit",750],"sword":["weapon",1500],"col5":["collar",1500],"royal":["outfit",1800]}';
  sell_t jsonb := '{"bone":2,"ball":5,"frisbee":9,"toy":14,"stick":18,"star":40,"gift":30}';
  m jsonb; st jsonb; it text; slot text; pr int; lv int; c int := 0; x int := 0; n int; k text; bag int;
  cap int; tw_km numeric; tw_r numeric; tw_n int; tw_t int[] := array[0,30,100,210,380,500,590,615,665,730,765,810,830,875,915,965]; ok boolean := true; why text := null; nowe numeric := extract(epoch from now());
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

  elsif p_act = 'tw' then
    -- 環島台灣：依散步日記累積公里數算出拿到幾個城市印章，每個新印章 100 金幣（一次最多 5 個，算在每天金幣上限裡）
    select coalesce(sum(km), 0) into tw_km from public.pet_walks where pet_id = p_pet and km > 0;
    if tw_km <= 0 then tw_n := 0;
    else tw_r := tw_km - floor(tw_km / 1005) * 1005;
      tw_n := floor(tw_km / 1005)::int * 16 + (select count(*) from unnest(tw_t) t where t <= tw_r)::int; end if;
    n := least(tw_n - coalesce((m->>'tw')::int, 0), 5);
    if n <= 0 then ok := false; why := 'none';
    else n := least(n, greatest(cap - coalesce((m->>'earn')::int, 0), 0) / 100);
      if n <= 0 then ok := false; why := 'cap';
      else c := n * 100; g.coins := g.coins + c;
        m := m || jsonb_build_object('tw', coalesce((m->>'tw')::int, 0) + n, 'earn', coalesce((m->>'earn')::int, 0) + c, 'twc', c); end if; end if;

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
select 'walk_game v1.133 installed' as result;

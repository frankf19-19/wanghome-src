-- v1.108 案件頁的「收容所照片比對」改用快取
-- 問題：每次有人打開協尋頁，資料庫都要即時拿這隻毛孩的照片跟 6,800 多張收容所照片比一次（約 1 秒），
-- 一天幾百次瀏覽，免費方案的資料庫一直被佔住。每小時的排程本來就會算一樣的東西。
-- 做法：結果存進 case_photo_cache，1 小時內、而且毛孩照片沒變（sig）就直接用；每小時排程順便更新全部快取。
create table if not exists public.case_photo_cache (
  case_id uuid primary key references public.cases(id) on delete cascade,
  at timestamptz not null default now(),
  sig text,
  rows jsonb not null default '[]'
);
alter table public.case_photo_cache enable row level security;
revoke all on public.case_photo_cache from anon, authenticated;

-- 原本的即時計算（改名，只給內部用）
create or replace function public.case_photo_matches_raw(p_case uuid, p_limit int default 8)
returns table (ref text, url text, info jsonb, sim real)
language plpgsql stable security definer set search_path = public, extensions as $$
declare c record; n int := greatest(1, least(coalesce(p_limit, 8), 20)); d0 text;
begin
  select id, species, sex, lost_city, lost_at, status, hidden into c from public.cases where id = p_case;
  if not found or c.status <> 'searching' or c.hidden then return; end if;
  d0 := to_char((c.lost_at at time zone 'Asia/Taipei')::date - 1, 'YYYY-MM-DD');
  return query
    with q as (select p.vec, p.vec2 from public.photo_vecs p where p.kind = 'case' and p.ref = p_case::text and p.ver = 2),
    cand as (
      select s.ref, s.url, s.info,
             max(public.photo_score2(1 - (s.vec <=> q.vec), case when s.vec2 is not null and q.vec2 is not null then 1 - (s.vec2 <=> q.vec2) end)) as sc,
             max(1 - (s.vec <=> q.vec)) as cos
      from public.photo_vecs s cross join q
      where s.kind = 'shelter' and s.ver = 2
        and coalesce(s.info->>'sp', 'dog') = coalesce(c.species, 'dog')
        and coalesce(s.info->>'at', '9999') >= d0
        and not (coalesce(c.sex,'') = 'male' and coalesce(s.info->>'sex','') = '母') and not (coalesce(c.sex,'') = 'female' and coalesce(s.info->>'sex','') = '公')
      group by s.ref, s.url, s.info
    ), best as (
      select distinct on (cand.ref) cand.ref, cand.url, cand.info, cand.sc, cand.cos from cand order by cand.ref, cand.sc desc, cand.cos desc
    )
    select b.ref, b.url, b.info, b.sc from best b order by b.sc desc, b.cos desc limit n;
end $$;
revoke all on function public.case_photo_matches_raw(uuid, int) from public, anon, authenticated;

-- 這隻毛孩的照片特徵「指紋」：換照片、補算第二層特徵、改走失時間或性別都會變
create or replace function public.case_photo_sig(p_case uuid) returns text
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select coalesce((select string_agg(p.id::text || case when p.vec2 is null then 'a' else 'b' end, ',' order by p.id)
                   from public.photo_vecs p where p.kind = 'case' and p.ref = p_case::text and p.ver = 2), '')
      || '|' || coalesce((select c.species || c.sex || c.lost_at::text || c.status || c.hidden::text from public.cases c where c.id = p_case), '');
$$;
revoke all on function public.case_photo_sig(uuid) from public, anon, authenticated;

-- 重新計算並存快取（排程用；回傳前 20 名）
create or replace function public.case_photo_refresh(p_case uuid)
returns table (ref text, url text, info jsonb, sim real)
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare j jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(r) order by r.sim desc), '[]') into j from public.case_photo_matches_raw(p_case, 20) r;
  insert into public.case_photo_cache (case_id, at, sig, rows) values (p_case, now(), public.case_photo_sig(p_case), j)
    on conflict (case_id) do update set at = excluded.at, sig = excluded.sig, rows = excluded.rows;
  return query select x.ref, x.url, x.info, x.sim from jsonb_to_recordset(j) with ordinality as x(ref text, url text, info jsonb, sim real, o int) order by x.o;
exception when foreign_key_violation then return;   -- 案件剛好被刪掉
end $$;
revoke all on function public.case_photo_refresh(uuid) from public, anon, authenticated;

-- 協尋頁呼叫的版本：快取 1 小時內而且指紋一樣就直接回，不然重算
create or replace function public.case_photo_matches(p_case uuid, p_limit int default 8)
returns table (ref text, url text, info jsonb, sim real)
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare n int := greatest(1, least(coalesce(p_limit, 8), 20)); k record;
begin
  select * into k from public.case_photo_cache where case_id = p_case;
  if found and k.at > now() - interval '1 hour' and k.sig = public.case_photo_sig(p_case) then
    return query select x.ref, x.url, x.info, x.sim from jsonb_to_recordset(k.rows) with ordinality as x(ref text, url text, info jsonb, sim real, o int) order by x.o limit n;
    return;
  end if;
  return query select * from public.case_photo_refresh(p_case) limit n;
end $$;
grant execute on function public.case_photo_matches(uuid, int) to anon, authenticated, service_role;

-- 每小時排程：改用 case_photo_refresh（順便把全部快取更新）
create or replace function public.sync_photo_matches() returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a int; b int; c int; d int;
begin
  -- 收容所：已有的配對更新相似度
  update public.shelter_matches m set photo_sim = x.sim, photo_checked_at = now()
  from (select m2.id, max(public.photo_score2(1 - (cv.vec <=> sv.vec), case when cv.vec2 is not null and sv.vec2 is not null then 1 - (cv.vec2 <=> sv.vec2) end))::int as sim
        from public.shelter_matches m2
        join public.cases cs on cs.id = m2.case_id and cs.status = 'searching'
        join public.photo_vecs cv on cv.kind = 'case' and cv.ref = m2.case_id::text and cv.ver = 2
        join public.photo_vecs sv on sv.kind = 'shelter' and sv.ref = m2.animal_id and sv.ver = 2
        where not m2.dismissed group by m2.id) x
  where m.id = x.id and m.photo_sim is distinct from x.sim;
  get diagnostics a = row_count;
  -- 收容所：每個協尋中的案件，照片最像的前 5 隻裡 75 分以上的補進來
  insert into public.shelter_matches (case_id, animal_id, animal_subid, shelter_name, shelter_tel, shelter_address, found_place, colour, bodytype, sex, variety, photo_url, score, photo_sim, photo_checked_at)
  select cs.id, r.ref, r.info->>'sub', r.info->>'shelter', r.info->>'tel', r.info->>'addr', r.info->>'place', r.info->>'colour', r.info->>'body', r.info->>'sex', r.info->>'variety', r.url, r.sim::int, r.sim::int, now()
  from public.cases cs cross join lateral (select * from public.case_photo_refresh(cs.id) limit 5) r
  where cs.status = 'searching' and not cs.hidden and r.sim >= 75
  on conflict (case_id, animal_id) do nothing;
  get diagnostics b = row_count;
  -- 路人通報：已有的配對更新相似度
  update public.found_matches m set photo_sim = x.sim
  from (select m2.id, public.photo_score(max(1 - (cv.vec <=> fv.vec)))::int as sim
        from public.found_matches m2
        join public.cases cs on cs.id = m2.case_id and cs.status = 'searching'
        join public.photo_vecs cv on cv.kind = 'case' and cv.ref = m2.case_id::text and cv.ver = 2
        join public.photo_vecs fv on fv.kind = 'found' and fv.ref = m2.found_id::text and fv.ver = 2
        group by m2.id) x
  where m.id = x.id and m.photo_sim is distinct from x.sim;
  get diagnostics c = row_count;
  -- 路人通報：照片 80 分以上的補進來（不限縣市，走失的毛孩可能跑很遠）
  insert into public.found_matches (case_id, found_id, score, photo_sim)
  select cs.id, r.ref::uuid, r.sim::int, r.sim::int
  from public.cases cs cross join lateral public.case_photo_found(cs.id, 5) r
  where cs.status = 'searching' and not cs.hidden and r.sim >= 80
  on conflict (case_id, found_id) do nothing;
  get diagnostics d = row_count;
  return json_build_object('shelter_updated', a, 'shelter_added', b, 'found_updated', c, 'found_added', d);
end $$;
revoke all on function public.sync_photo_matches() from public, anon, authenticated;
grant execute on function public.sync_photo_matches() to service_role;

-- 驗證：快取結果和即時計算一樣、第二次呼叫變快
create temp table if not exists _v108(k text, v text); truncate _v108;
do $$ declare cid uuid; t0 timestamptz; a jsonb; b jsonb; begin
  select c.id into cid from public.cases c join public.photo_vecs p on p.kind = 'case' and p.ref = c.id::text and p.ver = 2
   where c.status = 'searching' and not c.hidden limit 1;
  select coalesce(jsonb_agg(r.ref order by r.sim desc), '[]') into a from public.case_photo_matches_raw(cid, 8) r;
  t0 := clock_timestamp(); perform * from public.case_photo_matches(cid, 8); insert into _v108 values ('first_ms', round(extract(epoch from clock_timestamp() - t0) * 1000)::text);
  t0 := clock_timestamp(); select coalesce(jsonb_agg(r.ref), '[]') into b from public.case_photo_matches(cid, 8) r; insert into _v108 values ('cached_ms', round(extract(epoch from clock_timestamp() - t0) * 1000)::text);
  insert into _v108 values ('same_result', (a = b)::text), ('n', jsonb_array_length(b)::text);
end $$;
select string_agg(k || '=' || v, ' , ') as v1_108 from _v108;

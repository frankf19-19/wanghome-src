-- v1.104 照片清理改用資料庫自己找「哪些照片還在用」
-- 問題：daily-run 的照片清理用 order=id 讀 pet_cards，但 pet_cards 沒有 id 欄位 → 每晚都失敗（照片從沒清過）。
-- 而且它只看 cases/found_reports/sightings.photo_url/pet_cards，漏了 rehomes.photos、rehome_updates.photo、
-- sightings.photos、chat_messages.photo、profiles.avatar_url、pets.photos —— 直接修好會誤刪送養照片。
-- 改成：掃 public 所有資料表的文字/陣列/json 欄位，只要內容有 photos 空間的網址就算使用中（以後新增欄位也不會漏）。
create or replace function public.photo_refs() returns text[]
language plpgsql security definer set search_path = public, pg_catalog as $$
declare r record; out text[] := '{}'; part text[];
begin
  for r in
    select c.table_name t, c.column_name col
    from information_schema.columns c join information_schema.tables tb using (table_schema, table_name)
    where c.table_schema = 'public' and tb.table_type = 'BASE TABLE'
      and c.data_type in ('text', 'ARRAY', 'jsonb', 'json', 'character varying')
      and c.table_name not in ('photo_vecs')        -- 比對用的索引，不算「使用中」
  loop
    execute format(
      'select coalesce(array_agg(distinct m[1]), ''{}'') from public.%I, lateral regexp_matches(%I::text, ''/object/public/photos/([^"?,}\s\\]+)'', ''g'') m where %I::text like ''%%/object/public/photos/%%''',
      r.t, r.col, r.col) into part;
    out := out || part;
  end loop;
  return (select coalesce(array_agg(distinct x), '{}') from unnest(out) x);
end $$;
revoke all on function public.photo_refs() from public, anon, authenticated;
grant execute on function public.photo_refs() to service_role;
select cardinality(public.photo_refs()) as refs,
  (select count(*) from public.photo_refs() x(a), unnest(a) k where k like 'cases/%') as in_cases;

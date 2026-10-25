-- ============================================================
-- 汪回家 WangHome — 資料庫升級 v1.2
-- 收容所比對改由瀏覽器端執行（農業部開放資料擋台灣以外的 IP，
-- GitHub Actions 與 Supabase 東京機房都連不上），結果透過此 RPC 寫回。
-- 可重複執行，不刪資料。
-- ============================================================

create or replace function public.report_shelter_matches(p_case uuid, p_rows jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_n integer := 0;
  r jsonb;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 30 then
    raise exception '資料格式錯誤';
  end if;
  if not exists (select 1 from public.cases where id = p_case and status = 'searching') then
    return 0;
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into public.shelter_matches (
      case_id, animal_id, animal_subid, shelter_name, shelter_tel, shelter_address, found_place,
      colour, bodytype, sex, age, variety, photo_url, open_date, score
    ) values (
      p_case,
      left(r->>'animal_id', 30),
      left(r->>'animal_subid', 40),
      left(r->>'shelter_name', 60),
      left(r->>'shelter_tel', 30),
      left(r->>'shelter_address', 120),
      left(r->>'found_place', 120),
      left(r->>'colour', 20),
      left(r->>'bodytype', 10),
      left(r->>'sex', 10),
      left(r->>'age', 10),
      left(r->>'variety', 30),
      case when r->>'photo_url' like 'https://www.pet.gov.tw/%' then left(r->>'photo_url', 200) else null end,
      case when r->>'open_date' ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'open_date')::date else null end,
      greatest(0, least(100, coalesce((r->>'score')::integer, 0)))
    )
    on conflict (case_id, animal_id) do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;

grant execute on function public.report_shelter_matches(uuid, jsonb) to anon, authenticated;

select 'WangHome migration v1.2 installed' as result;

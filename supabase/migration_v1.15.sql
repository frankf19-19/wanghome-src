-- 汪喵回家 migration v1.15 — 安全性加固
--   1. 公開 view 一律不可寫入（雙重保險）
--   2. 網友回報目擊：只能填表單上的欄位；建立時間、飼主備註等由伺服器決定（防止繞過次數限制、假冒飼主備註）
--   3. 收容所比對：非飼主送來的資料不保存電話、地址、拾獲地（防止假冒收容所電話詐騙）
--   4. 通知信紀錄加上收件人，供寄信程式做「同一信箱每小時上限」與「全站上限」
--   5. 公開照片只能上傳到指定資料夾；寵物照片資料夾只限登入會員
-- 可重複執行。

-- 1 ---------------------------------------------------------------------------
do $$ declare v record; begin
  for v in select viewname from pg_views where schemaname = 'public' loop
    execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', v.viewname);
  end loop;
end $$;

-- 2 ---------------------------------------------------------------------------
revoke insert on public.sightings from anon, authenticated;
grant insert (case_id, seen_at, lat, lng, place_text, direction, note, photo_url, reporter_name, reporter_contact)
  on public.sightings to anon, authenticated;

create or replace function public.limit_sightings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.sightings where case_id = new.case_id and created_at > now() - interval '10 minutes') >= 30 then
    raise exception '這個案件短時間內回報太多次，請稍後再試';
  end if;
  new.created_at := now();
  new.status := 'pending';
  new.notified := false;
  new.reporter_id := auth.uid();
  new.owner_note := null;
  new.status_before_hide := null;
  return new;
end $$;

-- 3 ---------------------------------------------------------------------------
drop function if exists public.report_shelter_matches(uuid, jsonb);
create or replace function public.report_shelter_matches(p_case uuid, p_rows jsonb, p_token text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_n integer := 0;
  r jsonb;
  v_trusted boolean := public.can_manage_case(p_case, p_token);   -- 飼主自己的瀏覽器查到的才保存聯絡資訊
  v_name text;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 30 then
    raise exception '資料格式錯誤';
  end if;
  if not exists (select 1 from public.cases where id = p_case and status = 'searching') then
    return 0;
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_name := left(r->>'shelter_name', 60);
    if not v_trusted and (v_name ~ '[0-9０-９]' or v_name ~* '(http|line|www|@)') then v_name := null; end if;
    insert into public.shelter_matches (
      case_id, animal_id, animal_subid, shelter_name, shelter_tel, shelter_address, found_place,
      colour, bodytype, sex, age, variety, photo_url, open_date, score
    ) values (
      p_case,
      left(r->>'animal_id', 30),
      left(r->>'animal_subid', 40),
      v_name,
      case when v_trusted then left(r->>'shelter_tel', 30) end,
      case when v_trusted then left(r->>'shelter_address', 120) end,
      case when v_trusted then left(r->>'found_place', 120) end,
      left(r->>'colour', 20),
      left(r->>'bodytype', 10),
      left(r->>'sex', 10),
      left(r->>'age', 10),
      left(r->>'variety', 30),
      case when r->>'photo_url' like 'https://www.pet.gov.tw/%' then left(r->>'photo_url', 200) else null end,
      case when r->>'open_date' ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'open_date')::date else null end,
      greatest(0, least(100, coalesce((r->>'score')::integer, 0)))
    )
    on conflict (case_id, animal_id) do update set
      shelter_tel = coalesce(excluded.shelter_tel, public.shelter_matches.shelter_tel),
      shelter_address = coalesce(excluded.shelter_address, public.shelter_matches.shelter_address),
      found_place = coalesce(excluded.found_place, public.shelter_matches.found_place),
      shelter_name = coalesce(excluded.shelter_name, public.shelter_matches.shelter_name)
      where v_trusted;
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;
grant execute on function public.report_shelter_matches(uuid, jsonb, text) to anon, authenticated;

-- 4 ---------------------------------------------------------------------------
alter table public.case_mail_log add column if not exists to_email text;
create index if not exists case_mail_log_to_idx on public.case_mail_log(to_email, sent_at desc);
create index if not exists case_mail_log_time_idx on public.case_mail_log(sent_at desc);

-- 5 ---------------------------------------------------------------------------
drop policy if exists "anon upload photos" on storage.objects;
create policy "anon upload photos" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'photos' and (
    (storage.foldername(name))[1] in ('cases', 'found', 'sightings')
    or ((storage.foldername(name))[1] = 'pets' and auth.uid() is not null)
  ));

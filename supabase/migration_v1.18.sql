-- 汪喵回家 migration v1.18 — 修正 v1.17
--   收容所比對的讀取規則原本用一般權限查 cases 表，但 cases 表不開放直接讀取，
--   結果所有人都看不到比對結果。改用專門的檢查函式（只回答「這個案件有沒有被隱藏」）。
--   另外：v1.17 新增的長度限制只檢查新資料；舊資料如果超過，之後任何更新（回報目擊、標記找到）都會失敗。
--   這裡先把超過的舊資料截短，再正式啟用檢查。
-- 可重複執行。

create or replace function public.case_visible(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.cases where id = p_id and not hidden);
$$;
revoke all on function public.case_visible(uuid) from public;
grant execute on function public.case_visible(uuid) to anon, authenticated;

drop policy if exists "public read matches" on public.shelter_matches;
create policy "public read matches" on public.shelter_matches for select to anon, authenticated
  using (public.case_visible(case_id));

-- 長度限制：先修正舊資料，再啟用
update public.cases set
  contact_name  = left(contact_name, 50),
  contact_phone = left(contact_phone, 30),
  contact_line  = left(contact_line, 60),
  age_text      = left(age_text, 30),
  chip_last4    = left(chip_last4, 4),
  lost_district = left(lost_district, 20),
  lost_city     = left(lost_city, 10),
  contact_email = case when char_length(contact_email) > 120 then null else contact_email end,
  found_method  = case when found_method is null or found_method in ('','網友目擊回報','自己在附近找到','收容所／動保處通報','動物醫院掃晶片','FB／LINE 社團貼文','實體海報','鄰居／里長協助','外送員／郵差等看到','自己回家','其他') then found_method else '其他' end
where char_length(coalesce(contact_name,'')) > 50 or char_length(coalesce(contact_phone,'')) > 30
   or char_length(coalesce(contact_line,'')) > 60 or char_length(coalesce(age_text,'')) > 30
   or char_length(coalesce(chip_last4,'')) > 4 or char_length(coalesce(lost_district,'')) > 20
   or char_length(coalesce(lost_city,'')) > 10 or char_length(coalesce(contact_email,'')) > 120
   or not (found_method is null or found_method in ('','網友目擊回報','自己在附近找到','收容所／動保處通報','動物醫院掃晶片','FB／LINE 社團貼文','實體海報','鄰居／里長協助','外送員／郵差等看到','自己回家','其他'));
alter table public.cases validate constraint cases_len2;

update public.found_reports set
  reporter_phone = left(reporter_phone, 30),
  reporter_line  = left(reporter_line, 60),
  district       = left(district, 20),
  city           = left(city, 10),
  injury         = left(injury, 200),
  reporter_email = case when char_length(reporter_email) > 120 then null else reporter_email end
where char_length(coalesce(reporter_phone,'')) > 30 or char_length(coalesce(reporter_line,'')) > 60
   or char_length(coalesce(district,'')) > 20 or char_length(coalesce(city,'')) > 10
   or char_length(coalesce(injury,'')) > 200 or char_length(coalesce(reporter_email,'')) > 120;
alter table public.found_reports validate constraint fr_len2;

select 'WangMiao migration v1.18 installed' as result;

-- 汪喵回家 migration v1.43 — 收容所照片：收容編號格式放寬（有些縣市是 S150812-01 這種格式）
--   到 Supabase → SQL Editor 整段執行。可重複執行。
drop policy if exists "shelter photo upload" on storage.objects;
create policy "shelter photo upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'photos' and name ~ '^shelter/[A-Za-z0-9-]{4,30}(_t)?\.jpg$' and public.photo_upload_ok());

create or replace function public.set_match_photo(p_subid text)
returns integer language plpgsql security definer set search_path = public, storage as $$
declare n integer;
begin
  if coalesce(p_subid, '') !~ '^[A-Za-z0-9-]{4,30}$' then return 0; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'photos' and name = 'shelter/' || p_subid || '.jpg') then return 0; end if;
  update public.shelter_matches
     set photo_url = 'https://nopyhfpaykkiieudvoko.supabase.co/storage/v1/object/public/photos/shelter/' || p_subid || '.jpg',
         photo_sim = null, photo_checked_at = null
   where btrim(animal_subid) = p_subid and coalesce(photo_url, '') not like '%/photos/shelter/%';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_match_photo(text) from public;
grant execute on function public.set_match_photo(text) to anon, authenticated;

select 'WangHome migration v1.43 installed' as result;

-- 汪喵回家 migration v1.42 — 收容所照片存到網站（給 AI 照片比對用）
--   到 Supabase → SQL Editor 整段執行。可重複執行。
--   寵物登記網只接受台灣的連線，排程主機在國外抓不到收容所照片。
--   改成：台灣的訪客打開協尋頁、看到收容所照片時，網站順手把一張小圖存到 photos/shelter/<收容編號>.jpg，
--   排程就能從網站自己的照片空間拿照片來做 AI 比對。
drop policy if exists "shelter photo upload" on storage.objects;
create policy "shelter photo upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'photos' and name ~ '^shelter/[A-Z]{5}[0-9]{6,20}(_t)?\.jpg$' and public.photo_upload_ok());

-- 照片存好後：把比對結果的照片換成網站裡的這張，並重新做 AI 比對
create or replace function public.set_match_photo(p_subid text)
returns integer language plpgsql security definer set search_path = public, storage as $$
declare n integer;
begin
  if coalesce(p_subid, '') !~ '^[A-Z]{5}[0-9]{6,20}$' then return 0; end if;
  if not exists (select 1 from storage.objects where bucket_id = 'photos' and name = 'shelter/' || p_subid || '.jpg') then return 0; end if;
  update public.shelter_matches
     set photo_url = 'https://nopyhfpaykkiieudvoko.supabase.co/storage/v1/object/public/photos/shelter/' || p_subid || '.jpg',
         photo_sim = null, photo_checked_at = null
   where animal_subid = p_subid and coalesce(photo_url, '') not like '%/photos/shelter/%';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_match_photo(text) from public;
grant execute on function public.set_match_photo(text) to anon, authenticated;

select 'WangHome migration v1.42 installed' as result;

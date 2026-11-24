-- v1.106 沒人收得到的目擊回報也進站長「待轉告」清單
-- 問題：admin_moa_sightings 只列農業部案件。網站上登記、但沒有會員帳號、也沒有驗證過 Email 的案件，
-- 收到目擊時飼主收不到通知（App 推播要帳號、Email 要驗證），站長清單也看不到 → 回報一直卡在「待確認」沒人處理。
create or replace function public.admin_moa_sightings(p_include_done boolean default false)
returns table(id uuid, case_id uuid, case_name text, species text, lost_city text, lost_district text, owner_phone text,
              seen_at timestamptz, created_at timestamptz, place_text text, direction text, note text, photo_url text,
              reporter_name text, reporter_contact text, status text, lat double precision, lng double precision)
language plpgsql stable security definer set search_path = public, extensions, pg_temp as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return query
  select s.id, c.id, c.name, c.species, c.lost_city, c.lost_district, c.contact_phone,
         s.seen_at, s.created_at, s.place_text, s.direction, s.note, s.photo_url, s.reporter_name, s.reporter_contact, s.status, s.lat, s.lng
  from public.sightings s join public.cases c on c.id = s.case_id
  where (c.source = 'moa'
         or (c.owner_id is null and (coalesce(btrim(c.contact_email), '') = '' or not coalesce(c.email_verified, false))))
    and (p_include_done or s.status = 'pending')
  order by s.created_at desc limit 200;
end $$;
revoke all on function public.admin_moa_sightings(boolean) from public, anon;
grant execute on function public.admin_moa_sightings(boolean) to authenticated;
select (select count(*) from public.sightings s join public.cases c on c.id = s.case_id
        where s.status = 'pending' and (c.source = 'moa' or (c.owner_id is null and (coalesce(btrim(c.contact_email), '') = '' or not coalesce(c.email_verified, false))))) as pending_now;

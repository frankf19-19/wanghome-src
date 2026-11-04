-- v1.59 座標防呆：台灣以外的座標一律不存（Google Play 審查機器人用模擬器送出的通報，GPS 預設在美國加州，
--        地圖就會顯示到國外）。縣市／鄉鎮欄位照舊，地圖改用地區中心點。
-- 另外刪掉 2026-11-03 那筆機器人測試通報（新北五股・ovppyo・座標在 Googleplex）。

create or replace function public.tw_only_coords() returns trigger language plpgsql as $$
declare
  ok boolean;
begin
  if tg_table_name = 'cases' then
    ok := new.lost_lat between 21.7 and 26.6 and new.lost_lng between 117.8 and 122.3;
    if new.lost_lat is not null and not coalesce(ok,false) then new.lost_lat := null; new.lost_lng := null; end if;
  elsif tg_table_name = 'profiles' then
    ok := new.home_lat between 21.7 and 26.6 and new.home_lng between 117.8 and 122.3;
    if new.home_lat is not null and not coalesce(ok,false) then new.home_lat := null; new.home_lng := null; end if;
  else
    ok := new.lat between 21.7 and 26.6 and new.lng between 117.8 and 122.3;
    if new.lat is not null and not coalesce(ok,false) then new.lat := null; new.lng := null; end if;
  end if;
  return new;
end $$;

drop trigger if exists tw_only_coords on public.cases;
create trigger tw_only_coords before insert or update on public.cases for each row execute function public.tw_only_coords();
drop trigger if exists tw_only_coords on public.found_reports;
create trigger tw_only_coords before insert or update on public.found_reports for each row execute function public.tw_only_coords();
drop trigger if exists tw_only_coords on public.sightings;
create trigger tw_only_coords before insert or update on public.sightings for each row execute function public.tw_only_coords();
drop trigger if exists tw_only_coords on public.profiles;
create trigger tw_only_coords before insert or update on public.profiles for each row execute function public.tw_only_coords();

-- 既有資料：把台灣以外的座標清掉
update public.cases set lost_lat = null, lost_lng = null
  where lost_lat is not null and not (lost_lat between 21.7 and 26.6 and lost_lng between 117.8 and 122.3);
update public.found_reports set lat = null, lng = null
  where lat is not null and not (lat between 21.7 and 26.6 and lng between 117.8 and 122.3);
update public.sightings set lat = null, lng = null
  where lat is not null and not (lat between 21.7 and 26.6 and lng between 117.8 and 122.3);

-- 刪掉審查機器人的測試通報
delete from public.found_reports where id = '8f1c0bd6-17d7-4cfb-9c70-7f736619c870';

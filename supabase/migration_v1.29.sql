-- 汪喵回家 migration v1.29 — 安全檢查第三輪
--   1. 公開照片：單檔上限 2MB → 1.5MB；全站每小時上限 1500 → 500 張（避免被大量亂傳塞爆空間）
--   2. 停權會員時，一併封鎖他最近 7 天發文用過的網路位址 30 天（避免登出後匿名繼續發）
-- 可重複執行。

-- 1 ---------------------------------------------------------------------------
-- 網站會先壓縮成 1280px、品質 82%，一般照片 200–700KB
update storage.buckets set file_size_limit = 1572864 where id = 'photos';

create or replace function public.photo_upload_ok() returns boolean
language sql volatile security definer set search_path = public as $$
  -- 每個網路位址每小時 60 張（一件登記最多 4 張照片＋縮圖＝8 個檔），全站每小時 500 張
  select case when public.client_ip() = 'unknown'
    then public.rate_ok('photo_noip', 500, interval '1 hour', 500, interval '1 hour')
    else public.rate_ok('photo', 60, interval '1 hour', 500, interval '1 hour') end;
$$;
revoke all on function public.photo_upload_ok() from public;
grant execute on function public.photo_upload_ok() to anon, authenticated;

-- 2 ---------------------------------------------------------------------------
create or replace function public.admin_ban_member(p_user uuid, p_reason text default null, p_days int default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_user = auth.uid() then raise exception '不能停權自己'; end if;
  insert into public.bans (user_id, reason, expires_at)
  values (p_user, left(p_reason, 200), case when p_days is not null then now() + make_interval(days => p_days) end);
  -- 他最近 7 天發文用過的網路位址也封鎖（最多 30 天：手機網路的位址會換人用，不永久封）
  insert into public.bans (ip, reason, expires_at)
  select distinct x.ip, left('（會員停權連帶）' || coalesce(p_reason, ''), 200),
         now() + make_interval(days => least(coalesce(p_days, 30), 30))
  from (
    select created_ip as ip from public.cases where owner_id = p_user and created_at > now() - interval '7 days'
    union select created_ip from public.found_reports where owner_id = p_user and created_at > now() - interval '7 days'
    union select created_ip from public.sightings where reporter_id = p_user and created_at > now() - interval '7 days'
  ) x
  where x.ip is not null and x.ip <> 'unknown'
    and not exists (select 1 from public.bans b where b.ip = x.ip and (b.expires_at is null or b.expires_at > now()));
end $$;
revoke all on function public.admin_ban_member(uuid, text, int) from public, anon;
grant execute on function public.admin_ban_member(uuid, text, int) to authenticated;

select 'v1.29 ok' as result,
  (select file_size_limit from storage.buckets where id = 'photos') as photo_limit;

-- 汪喵回家 migration v1.113 — QR 名牌：防濫用加強
--   原本只有「同一隻毛孩每小時 8 筆」：有人連按 8 次，真正撿到的人就送不出去。
--   改成：同一個網路位址每小時 6 筆（擋洗版的人）、同一隻毛孩每小時 20 筆、全站每小時 300 筆。可重複執行。
create or replace function public.pet_tag_scan(p_code text, p_lat double precision, p_lng double precision, p_acc real, p_msg text, p_contact text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pet uuid; v_id uuid;
begin
  select id into v_pet from public.pets where tag_code = upper(btrim(p_code)) and tag_on;
  if v_pet is null then raise exception '這個名牌目前沒有啟用'; end if;
  perform pg_advisory_xact_lock(hashtext('tag_scan:' || v_pet::text));
  if (select count(*) from public.pet_tag_scans where pet_id = v_pet and created_at > now() - interval '1 hour') >= 20 then
    raise exception '剛剛已經通知過飼主很多次了，請直接打電話或稍後再試';
  end if;
  perform public.rate_check('tag_scan', 6, interval '1 hour', 300, interval '1 hour');
  if p_lat is not null and (p_lng is null or p_lat < 20 or p_lat > 27 or p_lng < 117 or p_lng > 123.5) then p_lat := null; p_lng := null; p_acc := null; end if;   -- 只收台灣範圍內的位置
  if p_acc is not null and (p_acc < 0 or p_acc > 100000) then p_acc := null; end if;
  insert into public.pet_tag_scans (pet_id, lat, lng, acc, msg, contact)
  values (v_pet, p_lat, p_lng, p_acc, nullif(left(btrim(coalesce(p_msg, '')), 300), ''), nullif(left(btrim(coalesce(p_contact, '')), 60), ''))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.pet_tag_scan(text, double precision, double precision, real, text, text) from public;
grant execute on function public.pet_tag_scan(text, double precision, double precision, real, text, text) to anon, authenticated;
select 'ok' as r;

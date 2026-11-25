-- 汪喵回家 migration v1.115 — QR 名牌：掃描紀錄最多保存 180 天；飼主留言不能放網址（避免名牌頁被拿來貼廣告）
--   可重複執行。
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
  if p_lat is not null and (p_lng is null or p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180 or (p_lat = 0 and p_lng = 0)) then p_lat := null; p_lng := null; p_acc := null; end if;   -- 擋掉不合理的座標
  if p_acc is not null and (p_acc < 0 or p_acc > 100000) then p_acc := null; end if;
  insert into public.pet_tag_scans (pet_id, lat, lng, acc, msg, contact)
  values (v_pet, p_lat, p_lng, p_acc, nullif(left(btrim(coalesce(p_msg, '')), 300), ''), nullif(left(btrim(coalesce(p_contact, '')), 60), ''))
  returning id into v_id;
  if random() < 0.05 then delete from public.pet_tag_scans where created_at < now() - interval '180 days'; end if;   -- 掃描紀錄最多留 180 天
  return v_id;
end $$;
revoke all on function public.pet_tag_scan(text, double precision, double precision, real, text, text) from public;
grant execute on function public.pet_tag_scan(text, double precision, double precision, real, text, text) to anon, authenticated;

create or replace function public.pet_tag_set(p_pet uuid, p_on boolean, p_phone text, p_note text)
returns text language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_code text; v_try int := 0;
begin
  select tag_code into v_code from public.pets where id = p_pet and owner_id = auth.uid();
  if not found then raise exception '找不到這筆毛孩檔案'; end if;
  if coalesce(p_note, '') ~* '(https?://|www\.)' then raise exception '留言不能放網址'; end if;
  while v_code is null and v_try < 6 loop
    v_try := v_try + 1;
    select string_agg(substr('23456789ABCDEFGHJKMNPQRSTUVWXYZ', (get_byte(b, i) % 31) + 1, 1), '') into v_code
      from (select gen_random_bytes(10) as b) x, generate_series(0, 9) i;
    if exists (select 1 from public.pets where tag_code = v_code) then v_code := null; end if;
  end loop;
  if v_code is null then raise exception '產生代碼失敗，請再試一次'; end if;
  update public.pets set tag_code = v_code, tag_on = coalesce(p_on, false),
         tag_phone = nullif(left(regexp_replace(coalesce(p_phone, ''), '[^0-9+#, -]', '', 'g'), 20), ''),
         tag_note = nullif(left(btrim(coalesce(p_note, '')), 200), '')
   where id = p_pet and owner_id = auth.uid();
  return v_code;
end $$;
revoke all on function public.pet_tag_set(uuid, boolean, text, text) from public, anon;
grant execute on function public.pet_tag_set(uuid, boolean, text, text) to authenticated;
select 'ok' as r;

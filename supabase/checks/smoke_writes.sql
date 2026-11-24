-- 正式站「寫入」煙霧測試：用未登入／登入會員的身分實際跑一次主要的新增動作，每一項做完都自動復原（不留任何資料、不寄信）。
-- 在 Supabase SQL Editor 執行，結果每一行是一個動作：ok 或錯誤訊息。
create temp table if not exists _smoke(n int, who text, what text, result text);
truncate _smoke;
do $$
declare
  uid uuid := (select id from public.profiles where is_admin and username is not null limit 1);
  cid uuid := (select id from public.cases where status = 'searching' and not hidden and source is distinct from 'moa' order by created_at desc limit 1);
  pic text := (select u from public.cases, unnest(photos) u where u like '%/object/public/photos/cases/%' order by created_at desc limit 1);
  pid uuid; xid uuid; ch uuid; k int := 0;
  claims text;
  procedure_dummy int;
begin
  claims := json_build_object('sub', uid, 'role', 'authenticated')::text;

  -- ---------- 未登入 ----------
  k := k + 1; begin
    perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.9"}', true);
    perform set_config('role', 'anon', true);
    perform public.create_case(jsonb_build_object('species','dog','name','測試','sex','male','size','small','colour','白','features','測試',
      'photos', jsonb_build_array(pic),'lost_at', now() - interval '1 hour','lost_city','臺北市','lost_district','大安區','lost_place','測試',
      'contact_name','測試','contact_phone','0912345678','phone_public',false,'reward',0));
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'anon', '登記走失 create_case', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;

  k := k + 1; begin
    perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.10"}', true);
    perform set_config('role', 'anon', true);
    perform public.create_found(jsonb_build_object('species','dog','kind','injured','seen_at', now(),'city','臺北市','district','大安區','place_text','測試','lat',25.03,'lng',121.54,'photos', jsonb_build_array(pic),'phone_public',false));
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'anon', '通報受傷 create_found', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;

  k := k + 1; begin
    perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.11"}', true);
    perform set_config('role', 'anon', true);
    insert into public.sightings (case_id, seen_at, place_text, note, photo_url, reporter_name, reporter_contact)
      values (cid, now() - interval '10 minutes', '測試地點', '測試', pic, '測試', '0912345678');
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'anon', '回報目擊 sightings', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;

  k := k + 1; begin
    perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.12"}', true);
    perform set_config('role', 'anon', true);
    perform public.report_content('case', cid, 'other', '測試');
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'anon', '檢舉 report_content', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;

  -- ---------- 登入會員 ----------
  k := k + 1; begin
    perform set_config('request.jwt.claims', claims, true); perform set_config('role', 'authenticated', true);
    insert into public.rehomes (owner_id, species, name, sex, size, photos, city, contact_name, contact_phone, fee, story)
      values (uid, 'dog', '測試', 'male', 'small', array[pic], '臺北市', '測試', '0912345678', 0, '親人的小狗');
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'member', '刊登送養 rehomes', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;

  k := k + 1; begin
    perform set_config('request.jwt.claims', claims, true); perform set_config('role', 'authenticated', true);
    insert into public.pets (owner_id, species, name) values (uid, 'dog', '測試') returning id into pid;
    insert into public.pet_records (pet_id, kind, title, record_date) values (pid, 'vet', '測試', current_date);
    perform public.pet_share_create(pid, 7);
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'member', '新增毛孩＋病歷＋分享 pets/pet_records', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;

  k := k + 1; begin
    perform set_config('request.jwt.claims', claims, true); perform set_config('role', 'authenticated', true);
    perform public.case_comment_add(cid, '測試留言加油');
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'member', '案件留言 case_comment_add', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;

  k := k + 1; begin
    perform set_config('request.jwt.claims', claims, true); perform set_config('role', 'authenticated', true);
    insert into public.follows (user_id, case_id) values (uid, cid) on conflict do nothing;
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'member', '追蹤案件 follows', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;

  k := k + 1; begin
    perform set_config('request.jwt.claims', claims, true); perform set_config('role', 'authenticated', true);
    update public.profiles set notify_follow = notify_follow where id = uid;
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'member', '存通知設定 profiles', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;

  k := k + 1; begin
    perform set_config('request.jwt.claims', claims, true); perform set_config('role', 'authenticated', true);
    insert into public.pet_cards (pet_id, owner_id, species, name, photo, city)
      select p.id, uid, p.species, p.name, pic, '臺北市' from public.pets p where p.owner_id = uid and not exists (select 1 from public.pet_cards c where c.pet_id = p.id) limit 1;
    raise exception '__ok__';
  exception when others then insert into _smoke values (k, 'member', '名片牆 pet_cards', case when sqlerrm = '__ok__' then 'ok' else sqlerrm end); end;
end $$;
select string_agg(n || '. [' || who || '] ' || what || ' → ' || result, E'\n' order by n) as smoke from _smoke;

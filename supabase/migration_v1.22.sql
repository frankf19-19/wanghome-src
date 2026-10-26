-- 汪喵回家 migration v1.22 — App 上架前的內容管理與帳號刪除（Apple 1.2、5.1.1(v)；Google UGC、帳號刪除政策）
--   1. 自動過濾：案件、拾獲通報、目擊含詐騙／賭博／色情等字眼時，先隱藏並自動送站長審核
--   2. 停權：站長可停權發布者（會員帳號＋送出時的網路位址），被停權的人無法再發布
--   3. 公開資料多一欄 poster（發布者代號，無法反推身分），讓使用者「不再顯示這位發布者的內容」
--   4. 刪除帳號時可選擇一併刪除自己登記的案件、通報與目擊回報
--   送出時的網路位址只保存 30 天（定期清理會清掉）。
-- 可重複執行。

-- 1 ---------------------------------------------------------------------------
create or replace function public.ugc_bad(t text) returns boolean
language sql immutable as $$
  select coalesce(t, '') ~* '(匯款|轉帳|訂金|保證金|押金|贖金|贖回|點數卡|遊戲點數|博弈|娛樂城|百家樂|代儲|貸款|借錢|裸聊|約砲|約炮|援交|色情|成人影片|兼職賺|日賺|投資獲利|保證獲利|USDT|虛擬貨幣|加密貨幣|比特幣)';
$$;

create or replace function public.ugc_filter() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_text text; v_type text;
begin
  if tg_table_name = 'cases' then
    v_type := 'case';
    v_text := concat_ws(' ', new.name, new.breed, new.colour, new.features, new.collar_desc, new.temperament, new.lost_place, new.contact_name, new.contact_line, new.notes, new.found_note);
  elsif tg_table_name = 'found_reports' then
    v_type := 'found';
    v_text := concat_ws(' ', new.place_text, new.breed, new.colour, new.features, new.collar_desc, new.current_place, new.reporter_name, new.reporter_line, new.notes, new.injury);
  else
    v_type := 'sighting';
    v_text := concat_ws(' ', new.place_text, new.direction, new.note, new.reporter_name, new.reporter_contact);
  end if;
  if not public.ugc_bad(v_text) then return new; end if;
  if tg_op = 'UPDATE' and v_type <> 'sighting' then
    -- 修改時只有「新出現」可疑字眼才處理，避免站長恢復顯示後又被藏起來
    if v_type = 'case' and public.ugc_bad(concat_ws(' ', old.name, old.breed, old.colour, old.features, old.collar_desc, old.temperament, old.lost_place, old.contact_name, old.contact_line, old.notes, old.found_note)) then return new; end if;
    if v_type = 'found' and public.ugc_bad(concat_ws(' ', old.place_text, old.breed, old.colour, old.features, old.collar_desc, old.current_place, old.reporter_name, old.reporter_line, old.notes, old.injury)) then return new; end if;
  end if;
  if v_type = 'sighting' then
    if tg_op = 'UPDATE' then return new; end if;   -- 目擊只在新增時檢查（飼主改備註不影響）
    new.status := 'rejected';                      -- 不顯示、也不寄給飼主
  else
    new.hidden := true;
  end if;
  insert into public.reports (target_type, target_id, reason, note) values (v_type, new.id, 'inappropriate', '系統自動過濾：內容含可疑字眼，已先隱藏，請站長確認');
  return new;
end $$;

drop trigger if exists cases_ugc on public.cases;
create trigger cases_ugc before insert or update of name, breed, colour, features, collar_desc, temperament, lost_place, contact_name, contact_line, notes, found_note
  on public.cases for each row execute function public.ugc_filter();
drop trigger if exists found_ugc on public.found_reports;
create trigger found_ugc before insert or update of place_text, breed, colour, features, collar_desc, current_place, reporter_name, reporter_line, notes, injury
  on public.found_reports for each row execute function public.ugc_filter();
drop trigger if exists sightings_ugc on public.sightings;
create trigger sightings_ugc before insert on public.sightings for each row execute function public.ugc_filter();

-- 2 ---------------------------------------------------------------------------
alter table public.cases         add column if not exists created_ip text;
alter table public.found_reports add column if not exists created_ip text;
alter table public.sightings     add column if not exists created_ip text;
revoke update (created_ip) on public.cases, public.found_reports, public.sightings from anon, authenticated;

create table if not exists public.bans (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id    uuid references auth.users(id) on delete cascade,
  ip         text,
  reason     text,
  expires_at timestamptz,
  check (user_id is not null or ip is not null)
);
create index if not exists bans_user on public.bans(user_id);
create index if not exists bans_ip on public.bans(ip);
alter table public.bans enable row level security;
revoke all on public.bans from anon, authenticated;

create or replace function public.is_banned() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bans b
                  where (b.expires_at is null or b.expires_at > now())
                    and ((auth.uid() is not null and b.user_id = auth.uid())
                         or (b.ip is not null and b.ip = public.client_ip() and public.client_ip() <> 'unknown')));
$$;
revoke all on function public.is_banned() from public, anon, authenticated;

create or replace function public.ugc_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_banned() then
    raise exception '因違反使用規範，這個帳號或網路已無法再發布內容。如有疑問請寫信到 service@wangmiaotw.com';
  end if;
  new.created_ip := public.client_ip();
  return new;
end $$;
drop trigger if exists cases_guard on public.cases;
create trigger cases_guard before insert on public.cases for each row execute function public.ugc_guard();
drop trigger if exists found_guard on public.found_reports;
create trigger found_guard before insert on public.found_reports for each row execute function public.ugc_guard();
drop trigger if exists sightings_guard on public.sightings;
create trigger sightings_guard before insert on public.sightings for each row execute function public.ugc_guard();

-- 站長停權：找出這則內容的發布者（會員帳號＋送出時的網路位址），停權並隱藏該內容、結案檢舉
create or replace function public.admin_ban(p_type text, p_id uuid, p_reason text default null, p_days int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_ip text;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then select owner_id, created_ip into v_uid, v_ip from public.cases where id = p_id;
  elsif p_type = 'found' then select owner_id, created_ip into v_uid, v_ip from public.found_reports where id = p_id;
  elsif p_type = 'sighting' then select reporter_id, created_ip into v_uid, v_ip from public.sightings where id = p_id;
  else raise exception '類型錯誤'; end if;
  if not found then raise exception '找不到這則內容'; end if;
  if v_uid is null and (v_ip is null or v_ip = 'unknown') then
    perform public.admin_set_hidden(p_type, p_id, true);
    return jsonb_build_object('banned', false, 'hidden', true, 'note', '找不到發布者資料（超過 30 天的網路位址已清除），只隱藏內容');
  end if;
  insert into public.bans (user_id, ip, reason, expires_at)
  values (v_uid, nullif(v_ip, 'unknown'), left(p_reason, 200), case when p_days is not null then now() + make_interval(days => p_days) end);
  perform public.admin_set_hidden(p_type, p_id, true);
  update public.reports set resolved = true, resolved_at = now() where target_id = p_id and not resolved;
  return jsonb_build_object('banned', true, 'hidden', true, 'member', v_uid is not null);
end $$;
revoke all on function public.admin_ban(text, uuid, text, int) from public, anon;
grant execute on function public.admin_ban(text, uuid, text, int) to authenticated;

-- 3 ---------------------------------------------------------------------------
-- poster：發布者代號（會員＝同一人同一個代號；未登入的發布者＝每則各自一個），只用來在使用者自己的手機上封鎖
create or replace view public.cases_public with (security_invoker = false) as
select id, created_at, updated_at, last_activity, status, name, species, breed, sex, size,
       colour, age_text, features, has_chip, chip_last4, neutered, collar_desc, temperament,
       lost_at, lost_city, lost_district, lost_place, lost_lat, lost_lng, photos,
       contact_name,
       case when phone_public then contact_phone else null end as contact_phone,
       phone_public, contact_line, reward, notes, found_at, found_note, found_method, view_count,
       (select count(*) from public.sightings s where s.case_id = c.id and s.status='confirmed') as sighting_count,
       (select max(seen_at) from public.sightings s where s.case_id = c.id and s.status='confirmed') as last_seen_at,
       left(md5('wm-poster:' || coalesce(c.owner_id::text, 'c:' || c.id::text)), 12) as poster
from public.cases c
where not c.hidden;

create or replace view public.sightings_public with (security_invoker = false) as
select s.id, s.case_id, s.created_at, s.seen_at, s.lat, s.lng, s.place_text, s.direction, s.note, s.photo_url,
       s.reporter_name, s.status, s.owner_note, (s.reporter_id is not null) as verified,
       left(md5('wm-poster:' || coalesce(s.reporter_id::text, 's:' || s.id::text)), 12) as poster
from public.sightings s join public.cases c on c.id = s.case_id
where s.status = 'confirmed' and not c.hidden;

create or replace view public.found_public with (security_invoker = false) as
select id, created_at, updated_at, species, kind, status, seen_at, city, district, place_text, lat, lng,
       breed, sex, size, colour, features, collar_desc, current_place, photos, reporter_name,
       case when phone_public and status = 'open' then reporter_phone else null end as reporter_phone,
       phone_public, case when status = 'open' then reporter_line else null end as reporter_line, notes, injury,
       left(md5('wm-poster:' || coalesce(owner_id::text, 'f:' || id::text)), 12) as poster
from public.found_reports
where not hidden;
grant select on public.cases_public, public.sightings_public, public.found_public to anon, authenticated;

-- 4 ---------------------------------------------------------------------------
drop function if exists public.delete_my_account();
create or replace function public.delete_my_account(p_delete_content boolean default false)
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception '請先登入'; end if;
  if p_delete_content then
    -- 一併刪除：自己登記的案件（含目擊、比對）、拾獲／目擊通報、自己送出的目擊回報；照片會在幾天內自動清除
    delete from public.cases where owner_id = v_uid;
    delete from public.found_reports where owner_id = v_uid;
    delete from public.sightings where reporter_id = v_uid;
  else
    -- 保留給協尋（已公開的內容），只解除和帳號的連結；本人可用管理網址另外刪除
    update public.cases set owner_id = null where owner_id = v_uid;
    update public.found_reports set owner_id = null where owner_id = v_uid;
    update public.sightings set reporter_id = null where reporter_id = v_uid;
  end if;
  -- 刪除帳號：profiles、pets（含健康紀錄、用藥、打勾紀錄）、follows、notify_log 會跟著刪除
  delete from auth.users where id = v_uid;
end $$;
revoke all on function public.delete_my_account(boolean) from public, anon;
grant execute on function public.delete_my_account(boolean) to authenticated;

-- 5 ---------------------------------------------------------------------------
-- 定期清理多一項：送出時的網路位址保存 30 天
create or replace function public.clear_old_ips() returns int
language plpgsql security definer set search_path = public as $$
declare a int; b int; c int;
begin
  update public.cases set created_ip = null where created_ip is not null and created_at < now() - interval '30 days'; get diagnostics a = row_count;
  update public.found_reports set created_ip = null where created_ip is not null and created_at < now() - interval '30 days'; get diagnostics b = row_count;
  update public.sightings set created_ip = null where created_ip is not null and created_at < now() - interval '30 days'; get diagnostics c = row_count;
  return a + b + c;
end $$;
revoke all on function public.clear_old_ips() from public, anon, authenticated;
grant execute on function public.clear_old_ips() to service_role;

-- 6 ---------------------------------------------------------------------------
-- 飼主管理頁不需要的內部欄位不回傳（送出時的網路位址、確認信用的雜湊）
create or replace function public.owner_case(p_id uuid, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.cases;
begin
  if not public.can_manage_case(p_id, p_token) then raise exception '管理連結無效'; end if;
  select * into r from public.cases where id = p_id;
  return (to_jsonb(r) - 'edit_token' - 'created_ip' - 'email_verify_hash') || jsonb_build_object('is_mine', r.owner_id is not null and r.owner_id = auth.uid());
end $$;

select 'WangMiao migration v1.22 installed' as result;

-- v1.79 案件底下的「線索討論」
-- 登入的會員可以在協尋中的案件底下留言交換線索。
-- 防詐：留言裡的電話、網址顯示時自動遮掉；含匯款／訂金等字眼的留言不能送出。
-- 管理：會員可檢舉，3 個不同的人檢舉就先自動隱藏；發布案件的人可以隱藏自己案件底下的留言；管理員可隱藏、刪除、停權。

create table if not exists public.case_comments (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  case_id     uuid not null references public.cases(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  body        text not null check (char_length(body) between 2 and 500),
  hidden      boolean not null default false,
  created_ip  text
);
create index if not exists case_comments_case_idx on public.case_comments(case_id, created_at);
create index if not exists case_comments_user_idx on public.case_comments(user_id, created_at desc);
alter table public.case_comments enable row level security;   -- 不開放直接讀寫，一律走下面的函式

-- 顯示用：把電話和網址遮掉（原文仍保留在資料庫，管理員處理檢舉時看得到）
create or replace function public.comment_mask(t text) returns text
language sql immutable as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(coalesce(t, ''), '(https?://|www\.)[^\s，。、）)]+', '（連結已隱藏）', 'gi'),
             '(\+?886[\s-]?9|09)\d{2}[\s-]?\d{3}[\s-]?\d{3}', '（電話已隱藏）', 'g'),
           '\(?0\d{1,2}\)?[\s-]?\d{3,4}[\s-]?\d{4}', '（電話已隱藏）', 'g');
$$;

-- 讀取某個案件的留言（任何人都能看；被隱藏的只有留言者本人和管理員看得到）
create or replace function public.case_comments_list(p_case uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid; v_admin boolean := public.is_admin(); j jsonb;
begin
  select owner_id into v_owner from public.cases where id = p_case and (not hidden or v_admin);
  if not found then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'at', m.created_at, 'body', public.comment_mask(m.body),
           'name', coalesce(nullif(p.display_name, ''), p.username, '熱心網友'),
           'avatar', p.avatar_url,
           'mine', m.user_id = auth.uid(),
           'poster', v_owner is not null and m.user_id = v_owner,
           'hidden', m.hidden) order by m.created_at), '[]'::jsonb) into j
    from (select * from public.case_comments
           where case_id = p_case and (not hidden or user_id = auth.uid() or v_admin)
           order by created_at desc limit 200) m
    left join public.profiles p on p.id = m.user_id;
  return jsonb_build_object('rows', j, 'can_hide', v_admin or (v_owner is not null and v_owner = auth.uid()));
end $$;
revoke all on function public.case_comments_list(uuid) from public;
grant execute on function public.case_comments_list(uuid) to anon, authenticated;

-- 留言
create or replace function public.case_comment_add(p_case uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_body text := trim(regexp_replace(coalesce(p_body, ''), '\s*\n\s*\n\s*(\n\s*)+', E'\n\n', 'g')); v_id uuid; v_status text;
begin
  if auth.uid() is null then raise exception '請先登入再留言'; end if;
  if public.is_banned() then raise exception '因違反使用規範，這個帳號已無法再發布內容'; end if;
  select status into v_status from public.cases where id = p_case and not hidden;
  if not found then raise exception '找不到這個案件'; end if;
  if v_status <> 'searching' then raise exception '這個案件已經結案，不再開放留言'; end if;
  if char_length(v_body) < 2 then raise exception '請寫下你的線索'; end if;
  if char_length(v_body) > 500 then raise exception '留言最多 500 個字'; end if;
  if public.ugc_bad(v_body) then
    raise exception '留言裡有常被用來詐騙的字眼（例如匯款、訂金）。汪喵回家不會、飼主也不需要先付任何費用；請改寫後再送出';
  end if;
  if exists (select 1 from public.case_comments where case_id = p_case and user_id = auth.uid() and body = v_body) then
    raise exception '這則留言你已經送出過了';
  end if;
  if (select count(*) from public.case_comments where user_id = auth.uid() and created_at > now() - interval '10 minutes') >= 6 then
    raise exception '你剛剛留言太多次了，請過一會兒再試';
  end if;
  perform public.rate_check('comment', 12, interval '10 minutes', 400, interval '10 minutes');
  insert into public.case_comments (case_id, user_id, body, created_ip)
  values (p_case, auth.uid(), v_body, public.client_ip()) returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;
revoke all on function public.case_comment_add(uuid, text) from public, anon;
grant execute on function public.case_comment_add(uuid, text) to authenticated;

-- 刪除（自己的留言、管理員）或隱藏（發布案件的人對自己案件底下的留言）
create or replace function public.case_comment_remove(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare r record; v_owner uuid;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into r from public.case_comments where id = p_id;
  if not found then raise exception '找不到這則留言'; end if;
  if r.user_id = auth.uid() or public.is_admin() then
    delete from public.case_comments where id = p_id;
    update public.reports set resolved = true, resolved_at = now() where target_id = p_id and not resolved;
    return 'deleted';
  end if;
  select owner_id into v_owner from public.cases where id = r.case_id;
  if v_owner is not null and v_owner = auth.uid() then
    update public.case_comments set hidden = true where id = p_id;
    return 'hidden';
  end if;
  raise exception '只能刪除自己的留言';
end $$;
revoke all on function public.case_comment_remove(uuid) from public, anon;
grant execute on function public.case_comment_remove(uuid) to authenticated;

-- 檢舉：加入「留言」；3 個不同的人檢舉同一則留言就先自動隱藏，等管理員看
alter table public.reports drop constraint if exists reports_target_type_check;
alter table public.reports add constraint reports_target_type_check check (target_type in ('case','found','sighting','message','user','comment'));

create or replace function public.report_content(p_type text, p_id uuid, p_reason text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_ip text := public.client_ip();
begin
  if p_type not in ('case','found','sighting','comment') then raise exception '類型錯誤'; end if;
  if p_type = 'case' and not exists (select 1 from public.cases where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'found' and not exists (select 1 from public.found_reports where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'sighting' and not exists (select 1 from public.sightings where id = p_id) then raise exception '找不到內容'; end if;
  if p_type = 'comment' and not exists (select 1 from public.case_comments where id = p_id) then raise exception '找不到內容'; end if;
  -- 同一個人（會員或同一 IP）對同一內容只記一次
  if exists (select 1 from public.reports where target_id = p_id and not resolved
             and ((auth.uid() is not null and reporter_id = auth.uid()) or (v_ip <> 'unknown' and reporter_ip = v_ip))) then
    return;
  end if;
  perform public.rate_check('report', 20, interval '10 minutes', 500, interval '10 minutes');
  insert into public.reports (target_type, target_id, reason, note, reporter_id, reporter_ip)
  values (p_type, p_id, left(p_reason, 50), left(p_note, 500), auth.uid(), v_ip);
  if p_type = 'comment' and (select count(*) from public.reports where target_id = p_id and not resolved) >= 3 then
    update public.case_comments set hidden = true where id = p_id;
  end if;
end $$;
grant execute on function public.report_content(text, uuid, text, text) to anon, authenticated;

-- 管理後台：檢舉列表顯示留言內容
create or replace function public.admin_reports(p_include_resolved boolean default false)
returns table(id uuid, created_at timestamptz, target_type text, target_id uuid, reason text, note text,
              resolved boolean, target_title text, target_hidden boolean, report_count bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return query
  select r.id, r.created_at, r.target_type, r.target_id, r.reason, r.note, r.resolved,
         coalesce(c.name, case when f.id is not null then coalesce(f.colour,'') || ' ' || f.city end,
                  case when s.id is not null then '目擊：' || coalesce(s.place_text,'') end,
                  case when pu.id is not null then '會員：' || coalesce(pu.username, '（未設定名稱）') end,
                  case when m.id is not null then '留言（' || coalesce(mc.name, '') || '）：' || left(m.body, 200) end) as target_title,
         coalesce(c.hidden, f.hidden, s.status = 'rejected', m.hidden, false) as target_hidden,
         (select count(*) from public.reports r2 where r2.target_id = r.target_id and not r2.resolved) as report_count
  from public.reports r
  left join public.cases c on r.target_type = 'case' and c.id = r.target_id
  left join public.found_reports f on r.target_type = 'found' and f.id = r.target_id
  left join public.sightings s on r.target_type = 'sighting' and s.id = r.target_id
  left join public.profiles pu on r.target_type = 'user' and pu.id = r.target_id
  left join public.case_comments m on r.target_type = 'comment' and m.id = r.target_id
  left join public.cases mc on mc.id = m.case_id
  where p_include_resolved or not r.resolved
  order by r.resolved, r.created_at desc
  limit 300;
end $$;
revoke execute on function public.admin_reports(boolean) from anon, public;
grant execute on function public.admin_reports(boolean) to authenticated;

create or replace function public.admin_set_hidden(p_type text, p_id uuid, p_hidden boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then update public.cases set hidden = p_hidden where id = p_id;
  elsif p_type = 'found' then update public.found_reports set hidden = p_hidden where id = p_id;
  elsif p_type = 'comment' then update public.case_comments set hidden = p_hidden where id = p_id;
  elsif p_type = 'sighting' then
    if p_hidden then
      update public.sightings set status_before_hide = case when status <> 'rejected' then status else status_before_hide end,
                                  status = 'rejected' where id = p_id;
    else
      update public.sightings set status = coalesce(nullif(status_before_hide, 'rejected'), 'pending'),
                                  status_before_hide = null where id = p_id;
    end if;
  else raise exception '類型錯誤'; end if;
end $$;
revoke execute on function public.admin_set_hidden(text, uuid, boolean) from anon, public;
grant execute on function public.admin_set_hidden(text, uuid, boolean) to authenticated;

create or replace function public.admin_ban(p_type text, p_id uuid, p_reason text default null, p_days int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_ip text;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then select owner_id, created_ip into v_uid, v_ip from public.cases where id = p_id;
  elsif p_type = 'found' then select owner_id, created_ip into v_uid, v_ip from public.found_reports where id = p_id;
  elsif p_type = 'sighting' then select reporter_id, created_ip into v_uid, v_ip from public.sightings where id = p_id;
  elsif p_type = 'comment' then select user_id, created_ip into v_uid, v_ip from public.case_comments where id = p_id;
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

select 'WangHome migration v1.79 installed' as result;

-- v1.103 正式站每日健檢：health_check() 回傳發現的問題（空陣列 = 一切正常）。
-- 由 daily-run（nightly）每天呼叫，有問題就寄信給站長。只給 service_role 執行。
-- 背景：v1.90 的 rehomes 有 RLS 政策卻漏了 GRANT，送養刊登壞了好幾週沒人發現（v1.102 修正）。
create or replace function public.health_check() returns jsonb
language plpgsql security definer set search_path = public, pg_catalog as $$
declare
  probs text[] := '{}';
  x text; r record; parts text[]; ok boolean; n bigint; ts timestamptz;
  exp_priv text[] := array['anon:cases_public:SELECT','authenticated:cases_public:SELECT','anon:found_public:SELECT','authenticated:found_public:SELECT','anon:found_stats:SELECT','authenticated:found_stats:SELECT','anon:pet_card_week:SELECT','authenticated:pet_card_week:SELECT','anon:pet_cards_public:SELECT','authenticated:pet_cards_public:SELECT','anon:pet_meets_public:SELECT','authenticated:pet_meets_public:SELECT','anon:recent_sightings:SELECT','authenticated:recent_sightings:SELECT','anon:rehomes_public:SELECT','authenticated:rehomes_public:SELECT','anon:shelter_matches:SELECT','authenticated:shelter_matches:SELECT','anon:sightings_public:SELECT','authenticated:sightings_public:SELECT','anon:sponsors_public:SELECT','authenticated:sponsors_public:SELECT','authenticated:chat_members:SELECT','authenticated:chat_messages:SELECT','authenticated:chats:SELECT','authenticated:clinic_visits:INSERT','authenticated:clinic_visits:SELECT','authenticated:clinic_visits:UPDATE','authenticated:clinics:SELECT','authenticated:follows:DELETE','authenticated:follows:INSERT','authenticated:follows:SELECT','authenticated:pet_card_likers:SELECT','authenticated:pet_card_likes:DELETE','authenticated:pet_card_likes:INSERT','authenticated:pet_card_likes:SELECT','authenticated:pet_cards:DELETE','authenticated:pet_cards:INSERT','authenticated:pet_cards:SELECT','authenticated:pet_cards:UPDATE','authenticated:pet_clinic_links:DELETE','authenticated:pet_clinic_links:SELECT','authenticated:pet_med_logs:DELETE','authenticated:pet_med_logs:INSERT','authenticated:pet_med_logs:SELECT','authenticated:pet_meds:DELETE','authenticated:pet_meds:INSERT','authenticated:pet_meds:SELECT','authenticated:pet_meds:UPDATE','authenticated:pet_meet_board:SELECT','authenticated:pet_meet_joins:DELETE','authenticated:pet_meet_joins:INSERT','authenticated:pet_meet_joins:SELECT','authenticated:pet_meet_msgs:DELETE','authenticated:pet_meet_msgs:INSERT','authenticated:pet_meet_msgs:SELECT','authenticated:pet_meet_people:SELECT','authenticated:pet_meets:DELETE','authenticated:pet_meets:INSERT','authenticated:pet_meets:SELECT','authenticated:pet_meets:UPDATE','authenticated:pet_photos:DELETE','authenticated:pet_photos:INSERT','authenticated:pet_photos:SELECT','authenticated:pet_photos:UPDATE','authenticated:pet_records:DELETE','authenticated:pet_records:INSERT','authenticated:pet_records:SELECT','authenticated:pet_records:UPDATE','authenticated:pet_shares:DELETE','authenticated:pet_shares:SELECT','authenticated:pets:DELETE','authenticated:pets:INSERT','authenticated:pets:SELECT','authenticated:pets:UPDATE','authenticated:profiles:SELECT','authenticated:rehomes:INSERT','authenticated:rehomes:SELECT','authenticated:rehomes:UPDATE','authenticated:user_blocks:SELECT','anon:sightings:INSERT','authenticated:sightings:INSERT','authenticated:profiles:INSERT','authenticated:profiles:UPDATE'];
  rpc_auth text[] := array['admin_ban','admin_ban_member','admin_bans','admin_clinic_review','admin_clinics','admin_delete','admin_get_case','admin_list','admin_member_content','admin_members','admin_moa_sightings','admin_rehomes','admin_reports','admin_resolve','admin_set_hidden','admin_sighting_status','admin_site_posts','admin_stats','admin_unban','admin_update','bump_view','can_manage_case','can_manage_found','case_comment_add','case_comment_remove','case_comments_list','case_photo_found','case_photo_matches','case_photo_ready','chat_can','chat_hide','chat_list','chat_mark_unread','chat_mute','chat_open','chat_people','chat_pin','chat_react','chat_read','chat_read_all','chat_report','chat_send','chat_unread','chat_unsend','claim_by_email','claim_case','claim_found','clinic_apply','clinic_link_pet','clinic_pet','clinic_pets','clinic_visit_get','create_case','create_found','delete_case','delete_found','delete_my_account','dismiss_match','drop_push_token','friend_add','friend_code','friend_find','friend_list','friend_pending','friend_rel','friend_remove','friend_respond','is_admin','member_card','my_cases','my_clinic_id','my_found','my_pending_counts','owner_case','owner_found','owner_sightings','pet_clinic_visits','pet_clinics','pet_link_code','pet_share_create','pet_share_get','photo_search','rehome_agree','rehome_app_get','rehome_app_set','rehome_apply','rehome_apps_for','rehome_complete','rehome_decline_note','rehome_followups','rehome_inbox','rehome_meet_set','rehome_meets','rehome_my_apps','rehome_public_updates','rehome_share_set','rehome_update_add','rehome_updates_get','rehome_view','report_content','report_shelter_matches','rotate_calendar_token','save_push_token','set_health_alert','set_sighting_status','set_social_ok','set_username','update_case','update_found','user_block','user_report','username_available','verify_case_email'];
  rpc_anon text[] := array['bump_view','case_comments_list','case_photo_matches','create_case','create_found','owner_case','owner_found','owner_sightings','pet_share_get','photo_search','rehome_public_updates','rehome_view','report_content','username_available','verify_case_email','set_sighting_status','update_case','update_found'];
begin
  -- 1) 網站需要的資料表權限（整張表或至少一個欄位有權限就算有）
  foreach x in array exp_priv loop
    parts := string_to_array(x, ':');
    if to_regclass('public.' || parts[2]) is null then probs := probs || ('缺資料表：' || parts[2]); continue; end if;
    ok := has_table_privilege(parts[1], 'public.' || parts[2], parts[3])
       or (parts[3] in ('INSERT','UPDATE','SELECT') and has_any_column_privilege(parts[1], 'public.' || parts[2], parts[3]));
    if not ok then probs := probs || ('權限缺少：' || parts[1] || ' 不能 ' || parts[3] || ' ' || parts[2]); end if;
  end loop;

  -- 2) 通用檢查：有 RLS 政策開給會員，卻沒有對應的 GRANT（rehomes 那種 bug）
  for r in
    select c.relname, case p.polcmd when 'r' then 'SELECT' when 'a' then 'INSERT' when 'w' then 'UPDATE' when 'd' then 'DELETE' else 'ALL' end as cmd
    from pg_policy p join pg_class c on c.oid = p.polrelid join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and c.relrowsecurity
      and (p.polroles @> array['authenticated'::regrole::oid] or p.polroles @> array[0::oid])
  loop
    if r.cmd = 'ALL' then continue; end if;   -- ALL 政策常搭配只開部分權限，不判斷
    ok := has_table_privilege('authenticated', 'public.' || r.relname, r.cmd)
       or (r.cmd in ('INSERT','UPDATE','SELECT') and has_any_column_privilege('authenticated', 'public.' || r.relname, r.cmd));
    if not ok and r.cmd <> 'DELETE' then probs := probs || ('有政策沒權限：' || r.relname || ' ' || r.cmd); end if;
  end loop;

  -- 3) 網站呼叫的後台功能
  foreach x in array rpc_auth loop
    select bool_or(has_function_privilege('authenticated', p.oid, 'EXECUTE')) into ok
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = x;
    if ok is null then probs := probs || ('缺功能：' || x);
    elsif not ok then probs := probs || ('會員不能呼叫：' || x); end if;
  end loop;
  foreach x in array rpc_anon loop
    select bool_or(has_function_privilege('anon', p.oid, 'EXECUTE')) into ok
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = x;
    if ok is not true then probs := probs || ('未登入的人不能呼叫：' || x); end if;
  end loop;

  -- 4) 照片儲存空間
  if not exists (select 1 from storage.buckets where id = 'photos' and public) then probs := probs || '照片空間 photos 不見了或不是公開'::text; end if;

  -- 5) 排程（過去 26 小時失敗的）
  begin
    for r in select j.jobname, count(*) c from cron.job_run_details d join cron.job j using (jobid)
             where d.start_time > now() - interval '26 hours' and d.status = 'failed' group by 1 loop
      probs := probs || ('排程失敗：' || r.jobname || ' ' || r.c || ' 次');
    end loop;
  exception when others then probs := probs || ('讀不到排程紀錄：' || sqlerrm); end;

  -- 6) 農業部遺失申報同步（每 6 小時一次，超過 2 天沒新資料就提醒）
  select max(created_at) into ts from public.cases where source = 'moa';
  if ts is not null and ts < now() - interval '2 days' then
    probs := probs || ('農業部遺失申報 ' || extract(day from now() - ts)::int || ' 天沒有新資料，同步可能停了');
  end if;

  return (select coalesce(jsonb_agg(distinct v), '[]'::jsonb) from unnest(probs) v);
end $$;
revoke all on function public.health_check() from public, anon, authenticated;
grant execute on function public.health_check() to service_role;
select public.health_check() as v1_103;

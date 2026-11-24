-- v1.105 安全性小整理（Supabase Security Advisor）
-- 1) 醫院相關功能（v1.99）不需要給未登入的人呼叫：收回 anon 權限（函式內本來就有檢查身分，這是多一層保護）
revoke execute on function public.admin_clinics() from public, anon;
revoke execute on function public.clinic_pet(uuid) from public, anon;
revoke execute on function public.clinic_pets() from public, anon;
revoke execute on function public.clinic_visit_get(uuid) from public, anon;
revoke execute on function public.my_clinic_id() from public, anon;
revoke execute on function public.pet_clinic_visits(uuid) from public, anon;
revoke execute on function public.pet_clinics(uuid) from public, anon;
grant execute on function public.admin_clinics(), public.clinic_pet(uuid), public.clinic_pets(), public.clinic_visit_get(uuid),
  public.my_clinic_id(), public.pet_clinic_visits(uuid), public.pet_clinics(uuid) to authenticated;
-- 2) 固定 search_path（Function Search Path Mutable）；photo_score / photo_score2 不動：
--    它們是會被內嵌（inline）的 SQL 函式，比對時要算上百萬次，加 search_path 會變慢
do $$ declare r record; begin
  for r in select p.oid::regprocedure f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f'
             and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
             and p.proname not in ('photo_score', 'photo_score2')
             and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop execute format('alter function %s set search_path = public, extensions, pg_temp', r.f); end loop;
end $$;
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'
          and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')) as still_mutable,
       has_function_privilege('anon', 'public.admin_clinics()', 'execute') as anon_admin_clinics,
       has_function_privilege('authenticated', 'public.clinic_pets()', 'execute') as auth_clinic_pets,
       public.health_check() as health;

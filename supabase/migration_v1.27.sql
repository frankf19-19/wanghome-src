-- 汪喵回家 migration v1.27 — Supabase 安全／效能檢查建議
--   1. 需要登入才能用的函式（管理員、我的案件、綁定、日曆代碼）不再開放給未登入的訪客呼叫
--      （函式裡本來就會檢查身分；這裡是多一層保護）
--   2. 三個檢查函式固定 search_path
--   3. RLS 規則裡的 auth.uid() 改成 (select auth.uid())：每次查詢只算一次，資料多時比較快
-- 可重複執行。

-- 1 ---------------------------------------------------------------------------
revoke execute on function public.admin_get_case(uuid) from anon, public;
revoke execute on function public.admin_reports(boolean) from anon, public;
revoke execute on function public.admin_resolve(uuid) from anon, public;
revoke execute on function public.admin_set_hidden(text, uuid, boolean) from anon, public;
revoke execute on function public.admin_stats() from anon, public;
revoke execute on function public.my_cases() from anon, public;
revoke execute on function public.my_found() from anon, public;
revoke execute on function public.my_pending_counts() from anon, public;
revoke execute on function public.claim_case(uuid, text) from anon, public;
revoke execute on function public.claim_found(uuid, text) from anon, public;
revoke execute on function public.rotate_calendar_token() from anon, public;
grant execute on function public.admin_get_case(uuid), public.admin_reports(boolean), public.admin_resolve(uuid),
  public.admin_set_hidden(text, uuid, boolean), public.admin_stats(), public.my_cases(), public.my_found(),
  public.my_pending_counts(), public.claim_case(uuid, text), public.claim_found(uuid, text),
  public.rotate_calendar_token() to authenticated;

-- 2 ---------------------------------------------------------------------------
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('photo_url_ok', 'photo_urls_ok', 'ugc_bad') loop
    execute format('alter function %s set search_path = public', f.sig);
  end loop;
end $$;

-- 3 ---------------------------------------------------------------------------
do $$ declare r record; q text; w text; begin
  for r in select * from pg_policies where schemaname = 'public'
           and (coalesce(qual, '') ~ 'auth\.uid\(\)' or coalesce(with_check, '') ~ 'auth\.uid\(\)') loop
    q := r.qual; w := r.with_check;
    if q is not null and q !~* 'select auth\.uid\(\)' then
      execute format('alter policy %I on %I.%I using (%s)', r.policyname, r.schemaname, r.tablename,
                     regexp_replace(q, 'auth\.uid\(\)', '(select auth.uid())', 'g'));
    end if;
    if w is not null and w !~* 'select auth\.uid\(\)' then
      execute format('alter policy %I on %I.%I with check (%s)', r.policyname, r.schemaname, r.tablename,
                     regexp_replace(w, 'auth\.uid\(\)', '(select auth.uid())', 'g'));
    end if;
  end loop;
end $$;

select 'v1.27 ok' as result,
  (select count(*) from pg_policies where schemaname = 'public' and (coalesce(qual,'') ~ 'auth\.uid\(\)' or coalesce(with_check,'') ~ 'auth\.uid\(\)')
     and not (coalesce(qual,'') ~* 'select auth\.uid' or coalesce(with_check,'') ~* 'select auth\.uid')) as left_unwrapped;

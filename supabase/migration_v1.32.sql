-- 汪喵回家 migration v1.32 — 換信箱時，寄給舊信箱的「信件鑰匙」一併失效
--   飼主在管理頁改了 Email（或刪帳號時信箱被清空），舊信箱裡通知信的「到管理頁」按鈕不該再能進管理頁。
-- 可重複執行。
create or replace function public.case_email_verify() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare v_mail text;
begin
  if tg_op = 'INSERT' or new.contact_email is distinct from old.contact_email then
    new.email_verified := false;
    new.email_verify_hash := null;
    -- 不重設 email_verify_sent_at：換信箱也要等冷卻時間，避免被拿來連續寄信給不同人
    if tg_op = 'UPDATE' then delete from public.case_mail_keys where case_id = new.id; end if;
    if new.contact_email is not null and auth.uid() is not null
       and (new.owner_id = auth.uid() or tg_op = 'INSERT') then
      select email into v_mail from auth.users where id = auth.uid();
      if v_mail is not null and lower(btrim(v_mail)) = lower(btrim(new.contact_email)) then
        new.email_verified := true;
      end if;
    end if;
  end if;
  return new;
end $$;
select 'v1.32 ok' as result;

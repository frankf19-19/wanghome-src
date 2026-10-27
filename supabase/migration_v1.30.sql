-- 汪喵回家 migration v1.30 — 通知信裡的「到管理頁確認」可以直接進入管理
--   飼主的 Email 已經確認過是本人信箱，所以寄給他的通知信可以附一把「信件專用管理鑰匙」：
--   點信裡的按鈕就能直接管理，不用再找 LINE 裡的管理網址。
--   鑰匙 30 天後失效；資料庫只存雜湊值；原本的管理網址照常有效、不會被換掉。
-- 可重複執行。

create table if not exists public.case_mail_keys (
  key_hash   text primary key,
  case_id    uuid not null references public.cases(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists case_mail_keys_case on public.case_mail_keys(case_id);
alter table public.case_mail_keys enable row level security;   -- 沒有任何規則：網頁讀不到，只有下面的函式能用
revoke all on public.case_mail_keys from anon, authenticated;

-- 寄信程式（service_role）呼叫：產生一把鑰匙，回傳原始值放進信裡
create or replace function public.issue_mail_key(p_case uuid)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare v_key text := encode(gen_random_bytes(24), 'hex');
begin
  delete from public.case_mail_keys where expires_at < now();
  insert into public.case_mail_keys (key_hash, case_id, expires_at)
  values (encode(digest(v_key, 'sha256'), 'hex'), p_case, now() + interval '30 days');
  return v_key;
end $$;
revoke all on function public.issue_mail_key(uuid) from public, anon, authenticated;
grant execute on function public.issue_mail_key(uuid) to service_role;

-- 管理權限：原本的管理代碼、登入的擁有者，或 30 天內的信件鑰匙
create or replace function public.can_manage_case(p_id uuid, p_token text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.cases
    where id = p_id
      and ( (p_token is not null and p_token <> '' and edit_token = encode(digest(p_token,'sha256'),'hex'))
            or (auth.uid() is not null and owner_id = auth.uid()) )
  ) or (p_token is not null and p_token <> '' and exists (
    select 1 from public.case_mail_keys k
    where k.case_id = p_id and k.key_hash = encode(digest(p_token,'sha256'),'hex') and k.expires_at > now()
  ));
$$;

-- 綁定到帳號：信件鑰匙也可以（證明是信箱主人）
create or replace function public.claim_case(p_id uuid, p_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  update public.cases set owner_id = auth.uid()
   where id = p_id and owner_id is null
     and ( edit_token = encode(digest(coalesce(p_token,''),'sha256'),'hex')
           or exists (select 1 from public.case_mail_keys k where k.case_id = p_id
                      and k.key_hash = encode(digest(coalesce(p_token,''),'sha256'),'hex') and k.expires_at > now()) );
  if not found then raise exception '無法綁定（金鑰錯誤或已有擁有者）'; end if;
end $$;
revoke execute on function public.claim_case(uuid, text) from anon, public;
grant execute on function public.claim_case(uuid, text) to authenticated;

select 'v1.30 ok' as result;

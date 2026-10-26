-- 汪喵回家 migration v1.23 — 案件從「已找到」改回「協尋中」時，清掉找到的日期、說明與方式
--   （之前會保留舊資料：再標一次已找到時沿用舊日期，統計「怎麼找到的」也會算錯）
-- 可重複執行。

create or replace function public.update_case(p_id uuid, p_token text, p jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.can_manage_case(p_id, p_token) then raise exception '管理連結無效'; end if;
  -- 改聯絡信箱：每個 IP 每天 3 次，全站每小時 200 次
  if p ? 'contact_email' and nullif(btrim(p->>'contact_email'), '') is distinct from
     (select nullif(btrim(contact_email), '') from public.cases where id = p_id) then
    perform public.rate_check('email_change', 3, interval '1 day', 200, interval '1 hour');
  end if;
  update public.cases set
    status        = coalesce(nullif(p->>'status',''), status),
    name          = coalesce(p->>'name', name),
    breed         = coalesce(p->>'breed', breed),
    colour        = coalesce(p->>'colour', colour),
    features      = coalesce(p->>'features', features),
    collar_desc   = coalesce(p->>'collar_desc', collar_desc),
    temperament   = coalesce(p->>'temperament', temperament),
    lost_place    = coalesce(p->>'lost_place', lost_place),
    contact_name  = coalesce(p->>'contact_name', contact_name),
    contact_phone = coalesce(p->>'contact_phone', contact_phone),
    phone_public  = coalesce((p->>'phone_public')::boolean, phone_public),
    contact_email = coalesce(p->>'contact_email', contact_email),
    contact_line  = coalesce(p->>'contact_line', contact_line),
    reward        = coalesce((p->>'reward')::integer, reward),
    notes         = coalesce(p->>'notes', notes),
    photos        = case when p ? 'photos'
                      then coalesce((select array_agg(x) from jsonb_array_elements_text(p->'photos') x), '{}')
                      else photos end,
    found_at      = case when p->>'status' = 'found' then coalesce(found_at, now()) when p->>'status' = 'searching' then null else found_at end,
    found_note    = case when p->>'status' = 'searching' then null else coalesce(p->>'found_note', found_note) end,
    found_method  = case when p->>'status' = 'searching' then null else coalesce(p->>'found_method', found_method) end,
    updated_at    = now(),
    last_activity = now()
  where id = p_id;
end $$;
grant execute on function public.update_case(uuid,text,jsonb) to anon, authenticated;

-- 已經改回協尋中、但還留著找到資料的案件，一併清掉
update public.cases set found_at = null, found_note = null, found_method = null
 where status = 'searching' and (found_at is not null or found_note is not null or found_method is not null);

select 'WangMiao migration v1.23 installed' as result;

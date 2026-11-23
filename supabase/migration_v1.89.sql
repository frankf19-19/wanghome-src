-- 汪喵回家 migration v1.89 — 民眾送養區（優化）
--   1. 刊登的公開文字不能放電話、LINE、網址：電話要等送養人同意見面才交換（不讓人繞過審核）
--   2. 管理後台：送養列表（含已隱藏的），可以看申請數、檢舉數
--   可重複執行。

create or replace function public.rehome_contact_free(t text) returns boolean
language sql immutable as $$
  select coalesce(t, '') !~* '(0\s*9(\s*[-－.]?\s*[0-9０-９]){8}|０\s*９|line\s*(id)?\s*[:：]|加\s*(賴|line|LINE)|https?://|www\.|\.com\y|\.tw\y|lin\.ee|line\.me|@[a-z0-9_.]{3,})'
$$;

create or replace function public.rehomes_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare sys boolean := coalesce(current_setting('wh.rehome_sys', true), '') = '1';
begin
  if auth.uid() is not null and not sys then
    if tg_op = 'INSERT' then
      new.hidden := false; new.adopter_app := null; new.adopted_at := null;
      if new.status not in ('open','paused') then new.status := 'open'; end if;
      if (select count(*) from public.rehomes where owner_id = new.owner_id and created_at > now() - interval '1 day') >= 5 then
        raise exception '一天最多刊登 5 隻';
      end if;
      if not exists (select 1 from public.profiles where id = new.owner_id and username is not null) then
        raise exception '刊登送養前，請先設定會員 ID';
      end if;
    else
      new.hidden := old.hidden; new.owner_id := old.owner_id; new.adopter_app := old.adopter_app;
      new.adopted_at := old.adopted_at; new.created_at := old.created_at;
      if old.status = 'adopted' then new.status := 'adopted';
      elsif new.status = 'adopted' then new.status := old.status; end if;
    end if;
    if not public.rehome_contact_free(concat_ws(' ', new.name, new.breed, new.age_text, new.temperament, new.health, new.story, new.req_note, new.fee_note)) then
      raise exception '刊登內容請不要放電話、LINE 或網址。送養人同意見面之後，系統會自動交換電話';
    end if;
  end if;
  if not public.rehome_text_ok(concat_ws(' ', new.name, new.breed, new.temperament, new.health, new.story, new.req_note, new.fee_note)) then
    raise exception '送養區禁止買賣、配種相關內容';
  end if;
  if new.fee > 0 and coalesce(btrim(new.fee_note), '') = '' then
    raise exception '有收費用的話，請寫清楚是哪些實際花費（例如疫苗、結紮），交接時要附收據';
  end if;
  if exists (select 1 from public.bans b where b.user_id = new.owner_id and (b.expires_at is null or b.expires_at > now())) then
    raise exception '帳號已停權';
  end if;
  new.updated_at := now();
  return new;
end $$;

create or replace function public.admin_rehomes()
returns table(id uuid, name text, species text, city text, status text, hidden boolean, created_at timestamptz,
              updated_at timestamptz, owner_name text, username text, apps integer, reports integer, photo text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  return query
  select r.id, r.name, r.species, r.city, r.status, r.hidden, r.created_at, r.updated_at, r.contact_name, p.username,
         (select count(*)::int from public.rehome_apps a where a.rehome_id = r.id),
         (select count(*)::int from public.reports x where x.target_type = 'rehome' and x.target_id = r.id),
         r.photos[1]
    from public.rehomes r left join public.profiles p on p.id = r.owner_id
   order by r.created_at desc limit 300;
end $$;
revoke all on function public.admin_rehomes() from public, anon;
grant execute on function public.admin_rehomes() to authenticated;

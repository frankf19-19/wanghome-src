-- 汪喵回家 migration v1.92 — 民眾送養：瀏覽次數（只給送養人看，讓他知道有多少人看過）
--   可重複執行。
alter table public.rehomes add column if not exists view_count integer not null default 0;

-- 刊登的守門：使用者不能自己改瀏覽次數；系統更新（瀏覽次數、完成送養、站長隱藏）不算「送養人更新」
create or replace function public.rehomes_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare sys boolean := coalesce(current_setting('wh.rehome_sys', true), '') = '1';
begin
  if auth.uid() is not null and not sys then
    if tg_op = 'INSERT' then
      new.hidden := false; new.adopter_app := null; new.adopted_at := null; new.view_count := 0;
      if new.status not in ('open','paused') then new.status := 'open'; end if;
      if (select count(*) from public.rehomes where owner_id = new.owner_id and created_at > now() - interval '1 day') >= 5 then
        raise exception '一天最多刊登 5 隻';
      end if;
      if not exists (select 1 from public.profiles where id = new.owner_id and username is not null) then
        raise exception '刊登送養前，請先設定會員 ID';
      end if;
    else
      new.hidden := old.hidden; new.owner_id := old.owner_id; new.adopter_app := old.adopter_app;
      new.adopted_at := old.adopted_at; new.created_at := old.created_at; new.view_count := old.view_count;
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
  if not sys or tg_op = 'INSERT' then new.updated_at := now(); end if;
  return new;
end $$;

create or replace function public.rehome_view(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.rate_check('rehome_view', 120, interval '10 minutes', 3000, interval '10 minutes');
  perform set_config('wh.rehome_sys', '1', true);
  update public.rehomes set view_count = view_count + 1
   where id = p_id and status in ('open','paused') and not hidden and owner_id is distinct from auth.uid();
  perform set_config('wh.rehome_sys', '', true);
end $$;
grant execute on function public.rehome_view(uuid) to anon, authenticated;

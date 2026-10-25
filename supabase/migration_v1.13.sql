-- 汪喵回家 migration v1.13 — 管理後台「恢復顯示」目擊時回到原本狀態
-- 原本恢復一律變成「待飼主確認」，已確認的目擊恢復後會從地圖消失。
-- 可重複執行。

alter table public.sightings add column if not exists status_before_hide text;

create or replace function public.admin_set_hidden(p_type text, p_id uuid, p_hidden boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  if p_type = 'case' then update public.cases set hidden = p_hidden where id = p_id;
  elsif p_type = 'found' then update public.found_reports set hidden = p_hidden where id = p_id;
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
grant execute on function public.admin_set_hidden(text,uuid,boolean) to authenticated;

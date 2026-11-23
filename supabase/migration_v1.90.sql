-- 汪喵回家 migration v1.90 — 民眾送養區（修正）
--   1. 送養人不能直接刪除刊登（會連帶刪掉領養人的申請、切結書和近況），要下架請改成「下架」狀態
--   2. 「繁殖」不再整個擋：像「已結紮不會繁殖」這種正常描述會被誤擋；配種、借種、種公、種母照樣擋
--   可重複執行。

drop policy if exists "rehomes own" on public.rehomes;
drop policy if exists "rehomes own select" on public.rehomes;
drop policy if exists "rehomes own insert" on public.rehomes;
drop policy if exists "rehomes own update" on public.rehomes;
create policy "rehomes own select" on public.rehomes for select to authenticated using (owner_id = auth.uid());
create policy "rehomes own insert" on public.rehomes for insert to authenticated with check (owner_id = auth.uid());
create policy "rehomes own update" on public.rehomes for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
revoke delete on public.rehomes from anon, authenticated;

create or replace function public.rehome_text_ok(t text) returns boolean
language sql immutable as $$
  select coalesce(t, '') !~* '(販賣|出售|販售|代售|售價|價格|價錢|配種|借種|種公|種母|繁殖場|出清|轉讓費|賣場|私訊報價)'
$$;

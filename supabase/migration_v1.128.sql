-- 汪喵回家 migration v1.128 — 散步冒險「探索紀錄」存到伺服器：走過的路段、占過的地盤、本週挑戰統計、還沒放進背包的寶箱。
--   換手機或清掉瀏覽器資料也不會不見。只有毛孩的主人讀得到、寫得到；大小有上限。可重複執行。
create table if not exists public.pet_walk_ext (
  pet_id     uuid primary key references public.pets(id) on delete cascade,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.pet_walk_ext drop constraint if exists pet_walk_ext_size_chk;
alter table public.pet_walk_ext add constraint pet_walk_ext_size_chk check (jsonb_typeof(data) = 'object' and pg_column_size(data) <= 120000);
alter table public.pet_walk_ext enable row level security;
drop policy if exists "own pet walk ext" on public.pet_walk_ext;
create policy "own pet walk ext" on public.pet_walk_ext for all to authenticated
  using (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));
revoke all on public.pet_walk_ext from anon;
grant select, insert, update on public.pet_walk_ext to authenticated;
select 'pet_walk_ext installed' as result;

-- 汪喵回家 migration v1.71：照片找毛孩（AI 影像特徵）
-- 1) photo_vecs：協尋案件、拾獲通報、收容所毛孩的照片特徵（DINOv2，768 維；scripts/photo_index.py 每 6 小時更新）
-- 2) photo_search：給一張照片的特徵，回傳最像的毛孩（只回傳公開中的資料）
-- 3) sightings.photo_sim：目擊回報的照片和走失毛孩像不像（0～100；-1＝沒有照片可比）

create extension if not exists vector with schema extensions;

create table if not exists public.photo_vecs (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('case','found','shelter')),
  ref        text not null,
  url        text not null,
  vec        extensions.vector(768) not null,
  info       jsonb not null default '{}',
  seen_at    timestamptz not null default now(),
  unique (kind, ref, url)
);
create index if not exists photo_vecs_kind_ref on public.photo_vecs(kind, ref);
alter table public.photo_vecs enable row level security;   -- 不開放直接讀寫，只能透過 photo_search

create or replace function public.photo_search(q text, p_limit int default 24)
returns table (kind text, ref text, url text, info jsonb, sim real)
language sql stable security definer set search_path = public, extensions as $$
  with top as (
    select v.kind, v.ref, v.url, v.info, (1 - (v.vec <=> q::vector))::real as cos
    from public.photo_vecs v
    where (v.kind <> 'case'  or exists (select 1 from public.cases c where c.id::text = v.ref and c.status = 'searching' and not c.hidden))
      and (v.kind <> 'found' or exists (select 1 from public.found_reports f where f.id::text = v.ref and f.status = 'open' and not coalesce(f.hidden, false)))
    order by v.vec <=> q::vector
    limit 150
  ), best as (
    select distinct on (kind, ref) kind, ref, url, info, cos from top order by kind, ref, cos desc
  )
  select kind, ref, url, info, greatest(0, least(100, round(((cos - 0.30) / 0.50 * 100)::numeric)))::real as sim
  from best order by cos desc limit greatest(1, least(coalesce(p_limit, 24), 60));
$$;
revoke all on function public.photo_search(text, int) from public;
grant execute on function public.photo_search(text, int) to anon, authenticated, service_role;

alter table public.sightings add column if not exists photo_sim smallint;

select 'WangMiao migration v1.71 installed' as result;

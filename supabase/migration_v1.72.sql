-- 汪喵回家 migration v1.72：照片找毛孩改用「手機上跑的 AI」同一個模型（DINOv2-small 量化版，384 維）
-- photo_vecs 重建（v1.71 的 768 維還沒有資料）；photo_search 加上「狗／貓、縣市」篩選，三種來源各取最像的幾筆

drop function if exists public.photo_search(text, int);
drop table if exists public.photo_vecs;
create table public.photo_vecs (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('case','found','shelter')),
  ref        text not null,
  url        text not null,
  vec        extensions.vector(384) not null,
  info       jsonb not null default '{}',
  seen_at    timestamptz not null default now(),
  unique (kind, ref, url)
);
create index photo_vecs_kind_ref on public.photo_vecs(kind, ref);
alter table public.photo_vecs enable row level security;   -- 不開放直接讀寫，只能透過 photo_search
grant all on public.photo_vecs to service_role;
grant usage, select on all sequences in schema public to service_role;

create or replace function public.photo_search(q text, p_sp text default null, p_city text default null, p_limit int default 20)
returns table (kind text, ref text, url text, info jsonb, sim real)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v vector(384) := q::vector(384); k text; n int := greatest(1, least(coalesce(p_limit, 20), 40));
begin
  foreach k in array array['case','found','shelter'] loop
    return query
      with top as (
        select p.kind, p.ref, p.url, p.info, (1 - (p.vec <=> v))::real as cos
        from public.photo_vecs p
        where p.kind = k
          and (p_sp is null or p.info->>'sp' is null or p.info->>'sp' = p_sp)
          and (p_city is null or p.info->>'city' = p_city)
          and (k <> 'case'  or exists (select 1 from public.cases c where c.id::text = p.ref and c.status = 'searching' and not c.hidden))
          and (k <> 'found' or exists (select 1 from public.found_reports f where f.id::text = p.ref and f.status = 'open' and not coalesce(f.hidden, false)))
        order by p.vec <=> v
        limit n * 3
      ), best as (
        select distinct on (t.ref) t.kind, t.ref, t.url, t.info, t.cos from top t order by t.ref, t.cos desc
      )
      select b.kind, b.ref, b.url, b.info, greatest(0, least(100, round(((b.cos - 0.20) / 0.50 * 100)::numeric)))::real
      from best b order by b.cos desc limit n;
  end loop;
end $$;
revoke all on function public.photo_search(text, text, text, int) from public;
grant execute on function public.photo_search(text, text, text, int) to anon, authenticated, service_role;

alter table public.sightings add column if not exists photo_sim smallint;

select 'WangMiao migration v1.72 installed' as result;

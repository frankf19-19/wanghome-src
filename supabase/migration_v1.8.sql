-- ============================================================
-- 汪喵回家 — 資料庫升級 v1.8：路上受傷毛孩通報
--   found_reports.kind 增加 'injured'（看到受傷的狗貓）
--   found_reports.injury：傷勢描述（被車撞、流血、不能走…）
-- 可重複執行，不刪資料。
-- ============================================================
alter table public.found_reports drop constraint if exists found_reports_kind_check;
alter table public.found_reports add constraint found_reports_kind_check check (kind in ('found','seen','injured'));
alter table public.found_reports add column if not exists injury text;
alter table public.found_reports drop constraint if exists found_reports_injury_len;
alter table public.found_reports add constraint found_reports_injury_len check (char_length(coalesce(injury,'')) <= 200);

-- 公開 view：在最後加上 injury 欄位
create or replace view public.found_public with (security_invoker = false) as
select id, created_at, updated_at, species, kind, status, seen_at, city, district, place_text, lat, lng,
       breed, sex, size, colour, features, collar_desc, current_place, photos, reporter_name,
       case when phone_public then reporter_phone else null end as reporter_phone,
       phone_public, reporter_line, notes, injury
from public.found_reports
where not hidden;
grant select on public.found_public to anon, authenticated;

-- 建立通報 RPC：接受 kind=injured 與 injury
create or replace function public.create_found(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_token text := encode(gen_random_bytes(18), 'hex');
  v_id uuid;
  v_kind text := coalesce(nullif(p->>'kind',''),'seen');
begin
  if coalesce(p->>'city','') = '' or p->>'seen_at' is null then raise exception '缺少必填欄位'; end if;
  if v_kind not in ('found','seen','injured') then v_kind := 'seen'; end if;
  if (select count(*) from public.found_reports where created_at > now() - interval '10 minutes') > 60 then
    raise exception '目前送出太頻繁，請稍後再試';
  end if;
  insert into public.found_reports (
    species, kind, seen_at, city, district, place_text, lat, lng, breed, sex, size, colour, features,
    collar_desc, current_place, photos, reporter_name, reporter_phone, phone_public, reporter_email,
    reporter_line, notes, injury, edit_token
  ) values (
    case when p->>'species' = 'cat' then 'cat' else 'dog' end,
    v_kind, (p->>'seen_at')::timestamptz, p->>'city', p->>'district',
    p->>'place_text', (p->>'lat')::double precision, (p->>'lng')::double precision, p->>'breed',
    nullif(p->>'sex',''), nullif(p->>'size',''), p->>'colour', p->>'features', p->>'collar_desc',
    p->>'current_place',
    coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'photos','[]'::jsonb)) x), '{}'),
    p->>'reporter_name', p->>'reporter_phone', coalesce((p->>'phone_public')::boolean,true),
    p->>'reporter_email', p->>'reporter_line', p->>'notes', nullif(p->>'injury',''), encode(digest(v_token,'sha256'),'hex')
  ) returning id into v_id;
  return jsonb_build_object('id', v_id, 'token', v_token);
end $$;
grant execute on function public.create_found(jsonb) to anon, authenticated;

select 'WangMiao migration v1.8 installed' as result;

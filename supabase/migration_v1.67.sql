-- 汪喵回家 migration v1.67 — 毛孩交朋友：本週人氣毛孩
--   每張名片這 7 天被按喜歡的次數（只給數字，不透露是誰按的）。可重複執行。
create or replace view public.pet_card_week with (security_invoker = false) as
  select l.pet_id, count(*)::int as n
    from public.pet_card_likes l join public.pet_cards c on c.pet_id = l.pet_id
   where not c.hidden and l.created_at > now() - interval '7 days'
   group by l.pet_id;
grant select on public.pet_card_week to anon, authenticated;

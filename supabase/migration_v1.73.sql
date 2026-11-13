-- v1.73 收容所比對：清掉舊規則誤配的結果（2026-11-13）
-- 1. 米白／奶油色的毛孩，之前因為「米」字被當成黃色系，配到黃狗、黑黃色的狗
-- 2. 收容所公告日在走失日前一天之前的（走失前就已經在收容所，不可能是牠）
-- 3. 走失的是 1 歲以上，收容所的是幼犬／幼貓
update public.shelter_matches m set dismissed = true
from public.cases c
where m.case_id = c.id and m.dismissed = false and (
  (c.colour ~ '(米白|奶油|乳白|象牙)' and coalesce(m.colour, '') !~ '(白|米白|奶油)')
  or (m.open_date is not null and m.open_date < (c.lost_at at time zone 'Asia/Taipei')::date - 1)
  or (m.age in ('幼犬', '幼貓') and coalesce(substring(c.age_text from '(\d+(?:\.\d+)?)\s*歲'), '0')::numeric >= 1)
);

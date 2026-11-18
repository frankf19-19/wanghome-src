-- 中壢 Money（農業部案件）家人確認已離世，結案
update public.cases
set status = 'closed', found_at = now(), updated_at = now(),
    found_note = '家人已經確認 Money 的下落，很遺憾在走失期間遇到車禍，已經去當小天使了。謝謝大家這段時間的關心與幫忙，請不用再協尋了。'
where id = '60d08f66-c411-4b4a-b94e-bd43ca6f96a2'
returning id, status, found_note;

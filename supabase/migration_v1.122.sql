-- 汪喵回家 migration v1.122 — 毛孩在散步冒險裡的專屬可愛版圖片（照飼主上傳的照片畫的）。art 存圖片網址的開頭。可重複執行。
alter table public.pets add column if not exists art text;
alter table public.pets drop constraint if exists pets_art_chk;
alter table public.pets add constraint pets_art_chk check (art is null or char_length(art) <= 300);
update public.pets set art = '/art/pet/4fd3df1b-1d9a-47c2-a728-c09a33a40fce' where id = '4fd3df1b-1d9a-47c2-a728-c09a33a40fce';
select count(*) as pets_with_art from public.pets where art is not null;

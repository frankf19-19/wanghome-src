-- 汪喵回家 migration v1.123 — pets.art 只能是兩種：照片畫的專屬版（/art/pet/<毛孩id>）或飼主挑的現成角色（/art/k/<款式>）。可重複執行。
alter table public.pets drop constraint if exists pets_art_chk;
alter table public.pets add constraint pets_art_chk check (art is null or art ~ '^/art/(pet/[0-9a-f-]{36}|k/[a-z_]{3,30})$');
select count(*) as pets_with_art from public.pets where art is not null;

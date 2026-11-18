-- v1.82 收容所比對結果的性別用字改成「男生／女生」（不再用公／母）
update public.shelter_matches set sex = '男生' where sex = '公';
update public.shelter_matches set sex = '女生' where sex = '母';

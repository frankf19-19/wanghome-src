do $$
declare uid uuid; cid uuid; pid uuid; mid uuid; out text := '';
  procedure_dummy int;
begin
  select id into uid from public.profiles where is_admin order by created_at limit 1;
  select id into cid from public.cases where status='searching' order by created_at desc limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub',uid,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('audit.out', 'uid='||uid||' case='||coalesce(cid::text,'none'), true);
  execute 'set local role authenticated';
  -- helper pattern: each test in its own block
  begin update public.profiles set avatar_url=null where id=uid; perform set_config('audit.out',current_setting('audit.out')||' | prof.avatar OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | prof.avatar ERR '||sqlerrm,true); end;
  begin update public.profiles set dm_open=true where id=uid; perform set_config('audit.out',current_setting('audit.out')||' | prof.dm_open OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | prof.dm_open ERR '||sqlerrm,true); end;
  begin update public.profiles set notify_follow=true, notify_enabled=true where id=uid; perform set_config('audit.out',current_setting('audit.out')||' | prof.notify OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | prof.notify ERR '||sqlerrm,true); end;
  begin insert into public.pets(owner_id,name,species) values(uid,'稽核測試','dog') returning id into pid; perform set_config('audit.out',current_setting('audit.out')||' | pets.ins OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | pets.ins ERR '||sqlerrm,true); end;
  if pid is null then select id into pid from public.pets where owner_id=uid limit 1; end if;
  begin update public.pets set name='稽核測試2' where id=pid; perform set_config('audit.out',current_setting('audit.out')||' | pets.upd OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | pets.upd ERR '||sqlerrm,true); end;
  begin insert into public.pet_records(pet_id,kind,title,date) values(pid,'vaccine','測試',current_date); perform set_config('audit.out',current_setting('audit.out')||' | pet_records.ins OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | pet_records.ins ERR '||sqlerrm,true); end;
  begin insert into public.pet_cards(pet_id,species,name,city,district,tags) values(pid,'dog','稽核測試','臺北市','大安區','{親人}'); perform set_config('audit.out',current_setting('audit.out')||' | pet_cards.ins OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | pet_cards.ins ERR '||sqlerrm,true); end;
  begin insert into public.pet_card_likes(pet_id) values(pid); perform set_config('audit.out',current_setting('audit.out')||' | likes.own(should block) OK?!',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | likes.own blocked: '||sqlerrm,true); end;
  begin insert into public.pet_meets(species,title,place,city,district,starts_at) values('dog','稽核測試團','大安森林公園','臺北市','大安區',now()+interval '2 days') returning id into mid; perform set_config('audit.out',current_setting('audit.out')||' | pet_meets.ins OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | pet_meets.ins ERR '||sqlerrm,true); end;
  begin insert into public.pet_meet_msgs(meet_id,body) values(mid,'稽核測試留言'); perform set_config('audit.out',current_setting('audit.out')||' | meet_msgs.ins OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | meet_msgs.ins ERR '||sqlerrm,true); end;
  begin insert into public.pet_meet_joins(meet_id,pet_name) values(mid,'x'); perform set_config('audit.out',current_setting('audit.out')||' | joins.own(should block) OK?!',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | joins.own blocked: '||sqlerrm,true); end;
  begin perform 1 from public.pet_meet_board limit 1; perform 1 from public.pet_meet_people limit 1; perform 1 from public.pet_card_likers limit 1; perform set_config('audit.out',current_setting('audit.out')||' | views OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | views ERR '||sqlerrm,true); end;
  if cid is not null then
    begin insert into public.follows(case_id) values(cid); perform set_config('audit.out',current_setting('audit.out')||' | follows.ins OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | follows.ins ERR '||sqlerrm,true); end;
    begin insert into public.sightings(case_id,seen_at,place_text,note) values(cid,now()-interval '1 hour','稽核測試','測試'); perform set_config('audit.out',current_setting('audit.out')||' | sightings.ins(auth) OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | sightings.ins(auth) ERR '||sqlerrm,true); end;
  end if;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
  if cid is not null then
    begin insert into public.sightings(case_id,seen_at,place_text,note) values(cid,now()-interval '1 hour','稽核測試','測試'); perform set_config('audit.out',current_setting('audit.out')||' | sightings.ins(anon) OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | sightings.ins(anon) ERR '||sqlerrm,true); end;
  end if;
  begin perform 1 from public.pet_cards_public limit 1; perform 1 from public.pet_meets_public limit 1; perform 1 from public.cases_public limit 1; perform set_config('audit.out',current_setting('audit.out')||' | anon views OK',true); exception when others then perform set_config('audit.out',current_setting('audit.out')||' | anon views ERR '||sqlerrm,true); end;
  execute 'reset role';
  raise exception 'AUDIT(rolled back): %', current_setting('audit.out');
end $$;

/* ============================================================
   毛孩交朋友（第一版）：毛孩名片牆＋約散步
   - 主角是毛孩：名片只放毛孩的照片、品種、個性和所在的「區」
   - 想聊天：到飼主的會員頁加好友／私訊（沿用好友、私訊、檢舉、封鎖）
   - 禁止買賣、配種；約散步只能選公開地點（資料庫也會擋）
   ============================================================ */
const PAL_TAGS=['親人','親狗','親貓','怕生慢熟','活潑愛玩','溫和穩定','愛玩球','愛散步','愛吃','黏人','獨立','愛撒嬌','精力旺盛','老人家慢慢走','適合小型犬','大狗也 OK'];
const PAL_SIZE={small:'小型',medium:'中型',large:'大型'};
const PAL_SEX={male:'男生',female:'女生'};
const PAL_RULES=`<div class="notice pals-rules"><b>${ic('shield')} 交朋友守則</b><ul><li>只約公園、寵物餐廳這類公開地點，不要公開住址。</li><li>禁止買賣、配種、送養收費，違規會直接下架。</li><li>第一次見面先在大家看得到的地方，毛孩互相聞一聞、慢慢來。</li><li>遇到騷擾或可疑的人，到他的會員頁檢舉、封鎖。</li></ul></div>`;
const palBlocked=()=>new Set(lsList('wh_blocked'));
const palHidden=()=>new Set(lsList('wh_hidden'));
function palWhen(s){const t=tw(s),n=tw(new Date().toISOString());const wk='日一二三四五六'[new Date(new Date(s).getTime()+8*3600e3).getUTCDay()];
  const day=t.y===n.y&&t.m===n.m&&t.d===n.d?'今天':`${t.m}/${t.d}（${wk}）`;return `${day} ${String(t.h).padStart(2,'0')}:${String(t.mi).padStart(2,'0')}`}
function palFilterBar(st,tab){return `<div class="pals-filter"><div class="pchips">${[['','全部'],['dog','狗狗'],['cat','貓咪']].map(([v,l])=>`<button type="button" class="pchip ${st.sp===v?'on':''}" data-sp="${v}">${l}</button>`).join('')}</div>
  <select id="palCity" aria-label="縣市">${cityOptions(st.city).replace('選擇縣市','全部縣市')}</select></div>`}

async function renderPals(){const _n=navId;const q=qs(location.hash);const tab=q.tab==='meets'?'meets':'cards';
  const st={sp:['dog','cat'].includes(q.sp)?q.sp:'',city:q.city||''};
  setTitle('毛孩交朋友');
  const go=(o)=>{const p=new URLSearchParams({...(tab==='meets'?{tab:'meets'}:{}),...(st.sp?{sp:st.sp}:{}),...(st.city?{city:st.city}:{}),...o});for(const [k,v] of [...p])if(!v)p.delete(k);goReplace('#/pals'+(p.toString()?'?'+p:''))};
  app.innerHTML=`<div class="pals">
    <h1>${ic('paw')} 毛孩交朋友</h1>
    <p class="muted">幫毛孩找散步夥伴、玩伴。主角是毛孩，只顯示到「區」，不公開住址。</p>
    <div class="pals-tabs" role="tablist"><a role="tab" class="${tab==='cards'?'on':''}" href="#/pals${st.sp||st.city?'?'+new URLSearchParams({...(st.sp?{sp:st.sp}:{}),...(st.city?{city:st.city}:{})}):''}">毛孩名片牆</a><a role="tab" class="${tab==='meets'?'on':''}" href="#/pals?tab=meets${st.sp?'&sp='+st.sp:''}${st.city?'&city='+encodeURIComponent(st.city):''}">約散步</a></div>
    ${palFilterBar(st,tab)}
    <div class="pals-cta">${tab==='cards'?`<button type="button" class="btn green" id="palMine">${ic('plus')} 放上我的毛孩</button>`:`<a class="btn green" href="#/pals/meet/new">${ic('plus')} 發起約散步</a>`}</div>
    <div id="palList"><div class="empty loading" role="status"><span class="spin" aria-hidden="true"></span>載入中…</div></div>
    ${PAL_RULES}</div>`;
  app.querySelectorAll('[data-sp]').forEach(b=>b.onclick=()=>go({sp:b.dataset.sp}));
  $('#palCity').onchange=e=>go({city:e.target.value});
  {const b=$('#palMine');if(b)b.onclick=palPickMine}
  const bl=palBlocked(),hd=palHidden();
  if(tab==='cards'){
    let qy=sb.from('pet_cards_public').select('*').order('updated_at',{ascending:false}).limit(60);
    if(st.sp)qy=qy.eq('species',st.sp);if(st.city)qy=qy.eq('city',st.city);
    const {data,error}=await qy;if(_n!==navId)return;const box=$('#palList');
    if(error){box.innerHTML=netErrHTML();return}
    const rows=(data||[]).filter(c=>!bl.has(c.owner_id)&&!hd.has(c.pet_id));
    if(!rows.length){box.innerHTML=`<div class="empty-card"><div class="big">${ic('paw')}</div><b>${st.city||st.sp?'這個條件還沒有毛孩名片':'還沒有毛孩名片'}</b><p class="small">當第一個吧！把你家毛孩放上來，附近的毛孩就找得到牠。</p></div>`;return}
    box.innerHTML=`<div class="pals-grid">${rows.map((c,i)=>`<button type="button" class="pal-card" data-i="${i}"><span class="pal-ph ${c.species==='cat'?'cat':''}">${c.photo?thumbImg(c.photo,c.name):spIc(c.species)}</span><b>${esc(c.name)}</b><small>${esc([c.breed,c.age_text].filter(Boolean).join('・')||(c.species==='cat'?'貓咪':'狗狗'))}</small><small class="pal-loc">${ic('pin')} ${esc((c.city||'').replace(/^臺/,'台')+(c.district||''))}</small>${(c.tags||[]).length?`<span class="pal-tags">${c.tags.slice(0,3).map(t=>`<i>${esc(t)}</i>`).join('')}</span>`:''}</button>`).join('')}</div>`;
    box.querySelectorAll('.pal-card').forEach(b=>b.onclick=()=>palCardSheet(rows[+b.dataset.i]));
  }else{
    let qy=sb.from('pet_meets_public').select('*').order('starts_at',{ascending:true}).limit(60);
    if(st.sp)qy=qy.in('species',[st.sp,'any']);if(st.city)qy=qy.eq('city',st.city);
    const {data,error}=await qy;if(_n!==navId)return;const box=$('#palList');
    if(error){box.innerHTML=netErrHTML();return}
    const rows=(data||[]).filter(m=>!bl.has(m.owner_id)&&!hd.has(m.id));
    if(!rows.length){box.innerHTML=`<div class="empty-card"><div class="big">${ic('calendar')}</div><b>最近還沒有約散步</b><p class="small">發起一個吧！選一個公園和時間，附近的毛孩就能一起來。</p></div>`;return}
    box.innerHTML=`<div class="pals-meets">${rows.map(m=>`<a class="pal-meet" href="#/pals/meet/${m.id}"><span class="pm-when"><b>${esc(palWhen(m.starts_at))}</b><small>${m.species==='cat'?'貓咪':m.species==='dog'?'狗狗':'狗貓都可以'}${m.size_pref&&m.size_pref!=='any'?'・'+PAL_SIZE[m.size_pref]+'犬':''}</small></span><span class="pm-b"><b>${esc(m.title)}</b><small>${ic('pin')} ${esc((m.city||'').replace(/^臺/,'台')+(m.district||''))}・${esc(m.place)}</small><small>${esc(m.username)} 發起・${m.joined+1}/${m.cap} 人</small></span>${ic('chev','mrc')}</a>`).join('')}</div>`;
  }
}

function palCardSheet(c){const d=document.createElement('div');d.className='lightbox sheet-bg';d.setAttribute('aria-label',c.name+' 的名片');
  const mine=me()&&me().id===c.owner_id;
  d.innerHTML=`<div class="sheet pal-sheet" onclick="event.stopPropagation()">
    <div class="pal-big ${c.species==='cat'?'cat':''}">${c.photo?`<img src="${esc(safeU(c.photo))}" alt="${esc(c.name)}">`:spIc(c.species)}</div>
    <h2>${esc(c.name)}</h2>
    <p class="muted">${esc([c.species==='cat'?'貓咪':'狗狗',c.breed,c.sex&&PAL_SEX[c.sex],c.size&&PAL_SIZE[c.size],c.age_text].filter(Boolean).join('・'))}</p>
    <p class="pal-loc">${ic('pin')} ${esc((c.city||'').replace(/^臺/,'台')+(c.district||''))}</p>
    ${(c.tags||[]).length?`<p class="pal-tags">${c.tags.map(t=>`<i>${esc(t)}</i>`).join('')}</p>`:''}
    ${c.intro?`<p class="pal-intro">${esc(c.intro)}</p>`:''}
    <div class="pal-owner">${chatAva(c.username,c.avatar_url)}<span>飼主 <b>${esc(c.username)}</b></span></div>
    <div class="btns">${mine?`<a class="btn" href="#/pals/card/${c.pet_id}">${ic('edit')} 編輯名片</a>`:`<a class="btn green" href="#/u/${encodeURIComponent(c.username)}">${ic('userPlus')} 打招呼（到飼主頁加好友）</a>`}<button type="button" class="btn ghost" data-x>關閉</button></div>
    ${mine?'':`<p class="small" style="text-align:center;margin-top:10px"><button type="button" class="linkbtn" data-rep style="color:var(--ink-3)">檢舉這張名片</button></p>`}
  </div>`;
  d.onclick=()=>closeOverlay(d);openOverlay(d);requestAnimationFrame(()=>d.classList.add('show'));
  d.querySelector('[data-x]').onclick=()=>closeOverlay(d);
  {const r=d.querySelector('[data-rep]');if(r)r.onclick=()=>{closeOverlay(d);palReport(c.owner_id,c.pet_id,c.username)}}
}

async function palReport(owner,itemId,username){if(!me()){setReturn(location.hash);location.hash='#/login';return}
  const r=await new Promise(res=>xPick(`檢舉 ${username}`,[['spam','買賣、配種或廣告'],['inappropriate','不當照片或文字'],['fake','詐騙或假資料'],['other','其他']],null,res));
  if(!r)return;
  const {error}=await sb.rpc('user_report',{p_user:owner,p_reason:r,p_note:'毛孩交朋友：'+itemId});
  if(error)return toast('送出失敗：'+friendlyErr(error.message));
  lsAdd('wh_hidden',itemId);toast('謝謝，已收到檢舉，這則已從你的畫面隱藏',3500);route()}

async function palPickMine(){if(!me()){setReturn(location.hash);location.hash='#/login';return}
  const {data,error}=await sb.from('pets').select('id,name,species').order('created_at');if(error)return toast(friendlyErr(error.message));
  const pets=data||[];if(!pets.length){toast('先建立毛孩檔案，就能放上名片牆',3500);location.hash='#/pet/new';return}
  if(pets.length===1){location.hash='#/pals/card/'+pets[0].id;return}
  const id=await new Promise(res=>xPick('要放哪一隻？',pets.map(p=>[p.id,p.name]),null,res));if(id)location.hash='#/pals/card/'+id}

async function renderPalCard(petId){const _n=navId;if(!requireLogin())return;setTitle('毛孩名片');
  app.innerHTML='<div class="empty loading" role="status"><span class="spin" aria-hidden="true"></span>載入中…</div>';
  const [{data:p,error:e1},{data:c}]=await Promise.all([sb.from('pets').select('*').eq('id',petId).maybeSingle(),sb.from('pet_cards').select('*').eq('pet_id',petId).maybeSingle()]);
  if(_n!==navId)return;
  if(e1){app.innerHTML=netErrHTML();return}
  if(!p){app.innerHTML='<div class="empty">找不到這隻毛孩<br><a href="#/health">回我的毛孩</a></div>';return}
  const photos=(p.photos||[]).filter(Boolean);const cur=c&&c.photo;const tags=new Set(c?c.tags:[]);
  const city=c?c.city:'',dist=c?c.district:'';
  app.innerHTML=`<div class="pals narrow-in"><h1>${esc(p.name)}的交朋友名片</h1>
    <p class="muted">放上名片牆後，大家可以看到毛孩的照片、品種、個性和所在的「區」。<b>不會顯示你的聯絡方式、晶片號碼和健康紀錄。</b></p>
    <form id="pcf" novalidate>
      <h3>照片</h3>
      ${photos.length?`<div class="pal-photos">${photos.map((u,i)=>`<label><input type="radio" name="ph" value="${i}" ${(cur?false:i===0)?'checked':''}>${thumbImg(u,p.name)}</label>`).join('')}${cur?`<label><input type="radio" name="ph" value="keep" checked><img src="${esc(safeU(cur))}" alt="目前的名片照片"></label>`:''}</div>`:`<p class="small muted">這隻毛孩還沒有照片，名片會顯示圖示。<a href="#/pet/${p.id}/edit">去加照片</a></p>`}
      <h3>在哪一區</h3>
      <div class="row2"><label class="f"><span>縣市</span><select name="city" id="pcCity" required>${cityOptions(city)}</select></label><label class="f"><span>區</span><select name="district" id="pcDist">${distOptions(city,dist)}</select></label></div>
      <h3>個性（最多 6 個）</h3>
      <div class="pal-tagpick">${PAL_TAGS.map(t=>`<label class="pchip ${tags.has(t)?'on':''}"><input type="checkbox" name="tag" value="${esc(t)}" ${tags.has(t)?'checked':''}>${esc(t)}</label>`).join('')}</div>
      <label class="f"><span>一句話介紹<small class="hint">選填，200 字內</small></span><textarea name="intro" maxlength="200" placeholder="例如：很愛玩球，想找體型差不多的狗狗一起在河堤跑跑。">${esc(c&&c.intro||'')}</textarea></label>
      <div class="submitbar"><button class="btn green" id="pcSave">${c?'儲存名片':'放上名片牆'}</button>${c?`<button type="button" class="btn ghost danger" id="pcDel">從名片牆移除</button>`:''}</div>
    </form>${PAL_RULES}</div>`;
  $('#pcCity').onchange=e=>{$('#pcDist').innerHTML=distOptions(e.target.value)};
  app.querySelectorAll('.pal-tagpick input').forEach(i=>i.onchange=()=>{const n=app.querySelectorAll('.pal-tagpick input:checked').length;if(n>6){i.checked=false;toast('最多選 6 個');}i.closest('.pchip').classList.toggle('on',i.checked)});
  {const d=$('#pcDel');if(d)d.onclick=async()=>{if(!await askSheet({title:'從名片牆移除？',body:'移除後大家就看不到這張名片，之後可以再放上來。',ok:'移除',danger:true}))return;const {error}=await sb.from('pet_cards').delete().eq('pet_id',petId);if(error)return toast(friendlyErr(error.message));toast('已移除');location.hash='#/pals'}}
  $('#pcf').onsubmit=async e=>{e.preventDefault();const fd=new FormData(e.target);const b=$('#pcSave');
    if(!fd.get('city'))return fieldErr($('#pcCity'),'請選縣市');
    b.disabled=true;b.textContent='儲存中…';
    try{let photo=cur||null;const pv=fd.get('ph');
      if(pv!=null&&pv!=='keep'){const u=photos[+pv];const k=String(u).split('/object/public/photos/')[1];
        if(k&&k.startsWith('cases/'))photo=u;
        else if(k){const nk=`cases/pc-${Date.now()}-${Math.random().toString(36).slice(2,8)}.jpg`;const {error:ce}=await sb.storage.from('photos').copy(k,nk);
          if(ce)throw ce;sb.storage.from('photos').copy(k.replace(/\.jpg$/,'_t.jpg'),nk.replace(/\.jpg$/,'_t.jpg')).catch(()=>{});photo=sb.storage.from('photos').getPublicUrl(nk).data.publicUrl}}
      const row={pet_id:p.id,species:p.species,name:p.name,breed:p.breed||null,sex:p.sex||null,size:p.size||null,age_text:(petAge(p.birthday)||p.age_text||'').slice(0,20)||null,
        tags:fd.getAll('tag').slice(0,6),intro:(fd.get('intro')||'').trim()||null,city:fd.get('city'),district:fd.get('district')||null,photo};
      const {error}=await sb.from('pet_cards').upsert(row,{onConflict:'pet_id'});if(error)throw error;
      toast(c?'✅ 名片已更新':'🎉 已放上名片牆',3000);location.hash='#/pals'+(row.city?'?city='+encodeURIComponent(row.city):'');
    }catch(err){b.disabled=false;b.textContent=c?'儲存名片':'放上名片牆';toast(/買賣|配種/.test(err.message||'')?'名片裡不能有買賣、配種的內容':'儲存失敗：'+friendlyErr(err.message||err),4500)}};
}

function palLocalDT(d){const t=tw(d.toISOString());return `${t.y}-${String(t.m).padStart(2,'0')}-${String(t.d).padStart(2,'0')}T${String(t.h).padStart(2,'0')}:${String(t.mi).padStart(2,'0')}`}
async function renderMeetNew(){if(!requireLogin())return;setTitle('發起約散步');
  const min=new Date(Date.now()+30*60e3),max=new Date(Date.now()+29*864e5),def=new Date(Date.now()+864e5);def.setUTCMinutes(0);
  app.innerHTML=`<div class="pals narrow-in"><h1>發起約散步</h1>
    <form id="mtf" novalidate>
      <label class="f"><span>標題</span><input name="title" maxlength="40" required placeholder="例如：週六傍晚河堤小型犬跑跑"></label>
      <div class="row2"><label class="f"><span>誰可以來</span><select name="species"><option value="dog">狗狗</option><option value="cat">貓咪</option><option value="any">狗貓都可以</option></select></label>
      <label class="f"><span>體型</span><select name="size_pref"><option value="any">不限</option><option value="small">小型犬</option><option value="medium">中型犬</option><option value="large">大型犬</option></select></label></div>
      <label class="f"><span>時間</span><input type="datetime-local" name="starts_at" required min="${palLocalDT(min)}" max="${palLocalDT(max)}" value="${palLocalDT(def)}"></label>
      <div class="row2"><label class="f"><span>縣市</span><select name="city" id="mtCity" required>${cityOptions('')}</select></label><label class="f"><span>區</span><select name="district" id="mtDist">${distOptions('')}</select></label></div>
      <label class="f"><span>地點<small class="hint">公園、河濱、寵物餐廳這類公開地點</small></span><input name="place" maxlength="60" required placeholder="例如：大安森林公園 寵物公園"></label>
      <label class="f"><span>人數上限（含你）</span><input type="number" name="cap" min="2" max="30" value="8" required></label>
      <label class="f"><span>說明<small class="hint">選填，300 字內</small></span><textarea name="note" maxlength="300" placeholder="例如：會帶水和球，下雨就取消。"></textarea></label>
      <div class="submitbar"><button class="btn green" id="mtSave">發起</button></div>
    </form>${PAL_RULES}</div>`;
  $('#mtCity').onchange=e=>{$('#mtDist').innerHTML=distOptions(e.target.value)};
  $('#mtf').onsubmit=async e=>{e.preventDefault();const f=e.target,fd=new FormData(f);
    for(const n of ['title','starts_at','city','place']){const el=f.elements[n];if(!String(el.value).trim())return fieldErr(el)}
    const when=new Date(fd.get('starts_at')+':00+08:00');if(!(when>Date.now()))return fieldErr(f.elements.starts_at,'請選之後的時間');
    const b=$('#mtSave');b.disabled=true;b.textContent='送出中…';
    const row={title:fd.get('title').trim(),species:fd.get('species'),size_pref:fd.get('species')==='cat'?'any':fd.get('size_pref'),starts_at:when.toISOString(),city:fd.get('city'),district:fd.get('district')||null,place:fd.get('place').trim(),cap:Math.min(30,Math.max(2,+fd.get('cap')||8)),note:(fd.get('note')||'').trim()||null};
    const {data,error}=await sb.from('pet_meets').insert(row).select('id').single();
    if(error){b.disabled=false;b.textContent='發起';const m=error.message||'';return toast(/住家|買賣|30 天|最多/.test(m)?m.replace(/^.*?(請|交朋友|一天|時間)/,'$1'):'送出失敗：'+friendlyErr(m),5000)}
    toast('🎉 已發起，附近的毛孩就看得到了',3000);location.hash='#/pals/meet/'+data.id};
}

async function renderMeet(id){const _n=navId;setTitle('約散步');
  app.innerHTML='<div class="empty loading" role="status"><span class="spin" aria-hidden="true"></span>載入中…</div>';
  const {data:m,error}=await sb.from('pet_meets_public').select('*').eq('id',id).maybeSingle();if(_n!==navId)return;
  if(error){app.innerHTML=netErrHTML();return}
  if(!m){app.innerHTML=`<div class="empty-card"><b>這個活動已經結束或被移除了</b><a class="btn" href="#/pals?tab=meets">看其他約散步</a></div>`;return}
  const u=me();const host=u&&u.id===m.owner_id;
  let people=[];if(u){const {data}=await sb.from('pet_meet_people').select('*').eq('meet_id',id).order('created_at');people=data||[];if(_n!==navId)return}
  const joined=u&&people.some(x=>x.user_id===u.id);const full=m.joined+1>=m.cap;const past=new Date(m.starts_at)<Date.now();
  setTitle(m.title);
  app.innerHTML=`<div class="pals narrow-in pal-meet-page">
    <p class="muted"><a href="#/pals?tab=meets">← 約散步</a></p>
    <h1>${esc(m.title)}</h1>
    <dl class="kv"><dt>時間</dt><dd>${esc(palWhen(m.starts_at))}${past?'（已開始）':''}</dd><dt>地點</dt><dd>${esc((m.city||'').replace(/^臺/,'台')+(m.district||''))}・${esc(m.place)}</dd>
    <dt>誰可以來</dt><dd>${m.species==='cat'?'貓咪':m.species==='dog'?'狗狗':'狗貓都可以'}${m.size_pref&&m.size_pref!=='any'?'・'+PAL_SIZE[m.size_pref]+'犬':''}</dd><dt>人數</dt><dd>${m.joined+1} / ${m.cap} 人</dd></dl>
    ${m.note?`<p class="pal-intro">${esc(m.note)}</p>`:''}
    <a class="btn ghost sm" target="_blank" rel="noopener" href="https://www.google.com/maps/search/${encodeURIComponent((m.city||'')+(m.district||'')+' '+m.place)}">${ic('map')} 在地圖上看</a>
    <h3>參加的毛孩家長</h3>
    <div class="pal-people"><a href="#/u/${encodeURIComponent(m.username)}">${chatAva(m.username,m.avatar_url)}<span><b>${esc(m.username)}</b><small>發起人</small></span></a>${u?people.map(x=>`<a href="#/u/${encodeURIComponent(x.username)}">${chatAva(x.username,x.avatar_url)}<span><b>${esc(x.username)}</b>${x.pet_name?`<small>帶 ${esc(x.pet_name)}</small>`:''}</span></a>`).join(''):`<p class="small muted">登入後可以看到參加名單。</p>`}</div>
    <div class="btns" style="margin-top:16px">${host?`<button type="button" class="btn ghost danger" id="mtDel">取消這個活動</button>`:joined?`<button type="button" class="btn ghost" id="mtLeave">取消參加</button>`:past?'':full?`<button type="button" class="btn" disabled>名額已滿</button>`:`<button type="button" class="btn green" id="mtJoin">${ic('paw')} 我要參加</button>`}
      ${host?'':`<a class="btn ghost" href="#/u/${encodeURIComponent(m.username)}">${ic('chat')} 跟發起人聊聊</a>`}</div>
    ${host?'':`<p class="small" style="margin-top:12px"><button type="button" class="linkbtn" id="mtRep" style="color:var(--ink-3)">檢舉這個活動</button></p>`}
    ${PAL_RULES}</div>`;
  const again=()=>rerender(()=>renderMeet(id));
  {const b=$('#mtJoin');if(b)b.onclick=async()=>{if(!u){setReturn(location.hash);location.hash='#/login';return}
    const {data:pets}=await sb.from('pets').select('name,species').order('created_at');const ok=(pets||[]).filter(p=>m.species==='any'||p.species===m.species);
    let pn=null;if(ok.length===1)pn=ok[0].name;else if(ok.length>1){pn=await new Promise(res=>xPick('帶哪隻毛孩？',ok.map(p=>[p.name,p.name]),null,res));if(!pn)return}
    b.disabled=true;const {error}=await sb.from('pet_meet_joins').insert({meet_id:id,pet_name:pn});
    if(error){b.disabled=false;return toast(/已滿|結束/.test(error.message)?error.message.replace(/^.*?(名額|這個)/,'$1'):'沒有成功：'+friendlyErr(error.message),4000)}
    toast('🎉 已參加！記得準時到，臨時不能去請按「取消參加」',4000);again()}}
  {const b=$('#mtLeave');if(b)b.onclick=async()=>{const {error}=await sb.from('pet_meet_joins').delete().eq('meet_id',id).eq('user_id',u.id);if(error)return toast(friendlyErr(error.message));toast('已取消參加');again()}}
  {const b=$('#mtDel');if(b)b.onclick=async()=>{if(!await askSheet({title:'取消這個活動？',body:'已經參加的人會看不到這個活動，建議先私訊跟大家說一聲。',ok:'取消活動',danger:true}))return;const {error}=await sb.from('pet_meets').delete().eq('id',id);if(error)return toast(friendlyErr(error.message));toast('已取消活動');location.hash='#/pals?tab=meets'}}
  {const b=$('#mtRep');if(b)b.onclick=()=>palReport(m.owner_id,m.id,m.username)}
}

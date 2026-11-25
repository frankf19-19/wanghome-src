// 汪喵回家 — QR 名牌頁（/t/<代碼>）：撿到毛孩的人掃項圈上的 QR Code 會看到這一頁
//   不用登入、不用裝 App：看得到毛孩的名字和照片，可以直接打給飼主、把現在的位置和留言傳給飼主。
//   資料來自 pet_tag_view（只回飼主選擇公開的內容）；送出用 pet_tag_scan，再請 notify-sighting 推播給飼主。
const SUPABASE_URL = "https://nopyhfpaykkiieudvoko.supabase.co";
const ANON_KEY = "sb_publishable_WCeVQIAPH0UEEzhTwovqkg_lJ8Qjydb";
const SITE = "https://wangmiaotw.com/";
const SEX = { male: "男生", female: "女生" };
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const okImg = (u) => typeof u === "string" && /^https:\/\/nopyhfpaykkiieudvoko\.supabase\.co\/storage\/v1\/object\/public\/photos\/[^\s'"()<>\\]+$/.test(u) ? u : "";
const js = (v) => JSON.stringify(v).replace(/</g, "\\u003c").replace(/\u2028|\u2029/g, "");
const telHref = (p) => String(p || "").replace(/[^\d+#,]/g, "");

const CSS = `:root{--ink:#1F1B18;--mute:#6F6A64;--coral:#E8502E;--deep:#C2401F;--bg:#FBF6F1;--card:#fff;--line:#ECE4DC;--ok:#2F7D5B}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}body{margin:0;font-family:system-ui,"PingFang TC","Noto Sans TC","Microsoft JhengHei",sans-serif;background:var(--bg);color:var(--ink);line-height:1.6}
main{max-width:520px;margin:0 auto;padding:16px 16px 48px}
.brand{display:flex;align-items:center;gap:8px;color:var(--mute);font-size:14px;text-decoration:none;margin-bottom:12px}.brand img{width:22px;height:22px}
.ph{width:100%;aspect-ratio:4/3;object-fit:cover;border-radius:24px;background:#EFE7DF;display:block}
.noph{display:grid;place-items:center;font-size:72px}
h1{font-size:30px;line-height:1.25;margin:16px 0 2px}.who{color:var(--mute);margin:0 0 4px;font-size:16px}
.ask{font-size:18px;margin:10px 0 0}
.note{background:var(--card);border-left:5px solid var(--coral);border-radius:14px;padding:12px 16px;margin:16px 0 0;font-size:17px;white-space:pre-wrap;overflow-wrap:anywhere}
.note small{display:block;color:var(--mute);font-size:13px;margin-bottom:2px}
.btn{display:block;width:100%;text-align:center;border:0;font:inherit;font-weight:800;font-size:19px;padding:17px 14px;border-radius:18px;margin-top:14px;text-decoration:none;cursor:pointer;background:linear-gradient(180deg,#F2643D,#DC4824);color:#fff;box-shadow:0 10px 20px -12px rgba(220,72,36,.8)}
.btn.sec{background:var(--card);color:var(--ink);box-shadow:none;border:2px solid var(--line)}.btn[disabled]{opacity:.55}
.btn:focus-visible,input:focus-visible,textarea:focus-visible{outline:3px solid #1F1B18;outline-offset:2px}
.card{background:var(--card);border-radius:20px;padding:16px;margin-top:18px}.card h2{font-size:18px;margin:0 0 4px}.card p{margin:0 0 8px;color:var(--mute);font-size:15px}
label{display:block;font-weight:700;font-size:15px;margin:10px 0 4px}
input,textarea{width:100%;font:inherit;font-size:17px;padding:12px 14px;border:2px solid var(--line);border-radius:14px;background:#fff;color:var(--ink)}textarea{min-height:84px;resize:vertical}
#st{margin:12px 0 0;font-weight:700;min-height:1.6em}#st.ok{color:var(--ok)}#st.err{color:var(--deep)}
ul.tips{margin:6px 0 0;padding-left:20px}ul.tips li{margin:6px 0}
footer{color:var(--mute);font-size:13px;margin-top:26px;text-align:center}footer a{color:var(--mute)}`;

function page({ title, body, script = "" }) {
  return `<!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><meta name="robots" content="noindex,nofollow"><meta name="referrer" content="no-referrer">
<link rel="icon" href="${SITE}icon.svg" type="image/svg+xml"><style>${CSS}</style></head><body><main>
<a class="brand" href="${SITE}"><img src="${SITE}icon.svg" alt="">汪喵回家 QR 名牌</a>
${body}
<footer>汪喵回家是免費的走失狗貓協尋平台。<br><a href="${SITE}">wangmiaotw.com</a></footer>
</main>${script ? `<script>${script}</script>` : ""}</body></html>`;
}
const resp = (html, status = 200) => new Response(html, { status, headers: {
  "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff", "x-robots-tag": "noindex" } });

export async function tagPage(code) {
  code = String(code || "").toUpperCase().replace(/[^0-9A-Z]/g, "").slice(0, 16);
  let p = null, down = false;
  if (code.length >= 6) {
    try {
      const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/pet_tag_view`, { method: "POST", headers: { apikey: ANON_KEY, "Content-Type": "application/json", Accept: "application/json" }, body: JSON.stringify({ p_code: code }) });
      if (r.ok) p = await r.json(); else down = true;
    } catch (_) { down = true; }
  }
  if (!p || !p.name) {
    return resp(page({ title: "這個名牌目前沒有啟用｜汪喵回家", body: `<h1>${down ? "暫時讀不到名牌資料" : "這個名牌目前沒有啟用"}</h1>
<p class="ask">${down ? "請過一下再掃一次。" : "飼主可能還沒開啟，或已經關閉這個名牌。"}如果你撿到或看到走失的狗貓，可以這樣做：</p>
<div class="card"><ul class="tips"><li>不要追，慢慢靠近，先拍照、記下時間和地點。</li><li>帶到附近的動物醫院，可以免費掃晶片找飼主。</li><li>到汪喵回家登記「我看到／撿到一隻」，系統會比對走失協尋。</li><li>全國動保專線：1959</li></ul>
<a class="btn" href="${SITE}#/found">到汪喵回家登記</a><a class="btn sec" href="${SITE}g/found-pet">撿到狗貓怎麼辦</a></div>` }), down ? 503 : 404);
  }
  const name = esc(String(p.name).slice(0, 30)), cat = p.species === "cat";
  const who = [p.breed, SEX[p.sex], p.colour].map((x) => String(x || "").trim()).filter(Boolean).map(esc).join("・") || (cat ? "貓咪" : "狗狗");
  const img = okImg(p.photo), tel = telHref(p.phone);
  const body = `${img ? `<img class="ph" src="${esc(img)}" alt="${name}的照片">` : `<div class="ph noph" aria-hidden="true">${cat ? "🐱" : "🐶"}</div>`}
<h1>我是${name}</h1><p class="who">${who}</p>
<p class="ask">如果你撿到或看到我，請幫我聯絡家人，謝謝你。</p>
${p.note ? `<div class="note"><small>${name}的家人想跟你說</small>${esc(p.note)}</div>` : ""}
${tel ? `<a class="btn" href="tel:${esc(tel)}">打電話給${name}的家人</a>` : ""}
<button type="button" class="btn${tel ? " sec" : ""}" id="bLoc">把現在的位置傳給${name}的家人</button>
<div class="card"><h2>留言給家人</h2><p>不一定要填。留下怎麼聯絡你，家人可以回電。</p>
<label for="msg">想說的話</label><textarea id="msg" maxlength="300" placeholder="例如：我在公園門口，${name}在我旁邊"></textarea>
<label for="ct">你的電話或 LINE</label><input id="ct" maxlength="60" inputmode="text" autocomplete="tel">
<button type="button" class="btn sec" id="bMsg">只送留言，不傳位置</button>
<p id="st" role="status" aria-live="polite"></p></div>
<div class="card"><h2>請這樣幫忙</h2><ul class="tips"><li>不要追、不要大聲叫，蹲低慢慢靠近。</li><li>方便的話先留在原地，或帶到安全的地方。</li>${p.has_chip ? `<li>${name}有晶片，附近的動物醫院可以免費掃描。</li>` : ""}</ul></div>`;
  const script = `(function(){var C=${js(code)},U=${js(SUPABASE_URL)},K=${js(ANON_KEY)},N=${js(String(p.name).slice(0, 30))};
var st=document.getElementById('st'),bL=document.getElementById('bLoc'),bM=document.getElementById('bMsg'),busy=false;
function say(t,c){st.textContent=t;st.className=c||'';if(t)st.scrollIntoView({block:'nearest'})}
function send(pos){if(busy)return;busy=true;bL.disabled=bM.disabled=true;say('傳送中…');
  var b={p_code:C,p_lat:pos?pos.coords.latitude:null,p_lng:pos?pos.coords.longitude:null,p_acc:pos?Math.round(pos.coords.accuracy):null,p_msg:document.getElementById('msg').value,p_contact:document.getElementById('ct').value};
  fetch(U+'/rest/v1/rpc/pet_tag_scan',{method:'POST',headers:{apikey:K,'Content-Type':'application/json'},body:JSON.stringify(b)}).then(function(r){return r.json().then(function(j){return {ok:r.ok,j:j}})}).then(function(x){
    if(!x.ok){busy=false;bL.disabled=bM.disabled=false;say((x.j&&x.j.message)||'沒有送出，請再試一次，或直接打電話。','err');return}
    fetch(U+'/functions/v1/notify-sighting',{method:'POST',headers:{'Content-Type':'application/json',apikey:K},body:JSON.stringify({tag_scan:x.j})}).catch(function(){});
    say(pos?'已經把位置傳給'+N+'的家人了，謝謝你！':'留言已經送給'+N+'的家人了，謝謝你！','ok');bL.textContent='已傳送';bM.hidden=true
  }).catch(function(){busy=false;bL.disabled=bM.disabled=false;say('網路不穩，沒有送出。請再試一次，或直接打電話。','err')})}
bL.onclick=function(){if(!navigator.geolocation){say('這支手機沒辦法取得位置，請改用留言或直接打電話。','err');return}
  say('正在取得位置…（手機問你要不要允許時，請按允許）');
  navigator.geolocation.getCurrentPosition(send,function(){say('沒有取得位置。可以在留言寫下你在哪裡，再按「只送留言」。','err')},{enableHighAccuracy:true,timeout:15000,maximumAge:60000})};
bM.onclick=function(){if(!document.getElementById('msg').value.trim()&&!document.getElementById('ct').value.trim()){say('請先寫一點留言，或留下聯絡方式。','err');return}send(null)};
})();`;
  return resp(page({ title: `我是${String(p.name).slice(0, 30)}，請幫我聯絡家人｜汪喵回家 QR 名牌`, body, script }));
}

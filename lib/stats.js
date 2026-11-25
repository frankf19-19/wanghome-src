// 汪喵回家 — 公開統計頁與媒體資料頁（給搜尋引擎、AI 助理、記者引用）
//   /stats        台灣走失狗貓與收容所領養統計（每天自動更新）
//   /stats.json   同一份數字的機器可讀版本
//   /press        關於汪喵回家：媒體與合作資料
// 資料：本站協尋案件（含農業部寵物登記網遺失申報）＋農業部「動物認領養」開放資料
import { shell, resp } from "./guides.js";
import { adoptStats } from "./adopt.js";

const SITE = "https://wangmiaotw.com/";
const NAME = "汪喵回家";
const SUPABASE_URL = "https://nopyhfpaykkiieudvoko.supabase.co";
const ANON_KEY = "sb_publishable_WCeVQIAPH0UEEzhTwovqkg_lJ8Qjydb";
const CITIES = ["臺北市","新北市","桃園市","臺中市","臺南市","高雄市","基隆市","新竹市","新竹縣","苗栗縣","彰化縣","南投縣","雲林縣","嘉義市","嘉義縣","屏東縣","宜蘭縣","花蓮縣","臺東縣","澎湖縣","金門縣","連江縣"];
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const n = (x) => Number(x || 0).toLocaleString("en-US");
const pct = (a, b) => (b ? Math.round((a / b) * 100) : 0);
const tw = (t = Date.now()) => new Date(t + 8 * 3600e3);
const twDate = (t) => { const d = tw(t); return `${d.getUTCFullYear()}/${d.getUTCMonth() + 1}/${d.getUTCDate()}`; };
const normCity = (c) => String(c || "").replace(/^台/, "臺");

async function loadCases() {
  let all = [];
  for (let off = 0; off < 20000; off += 1000) {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/cases_public?select=species,status,lost_city,lost_at,found_at,source,created_at&order=created_at.desc&limit=1000&offset=${off}`,
      { headers: { apikey: ANON_KEY, Accept: "application/json" } });
    if (!r.ok) throw new Error("db " + r.status);
    const part = await r.json();
    all = all.concat(part);
    if (part.length < 1000) break;
  }
  return all;
}

// 算好的數字快取 1 小時（同一個機房），避免每次都撈整個資料庫
async function compute(waitUntil) {
  const key = new Request(`${SITE}__stats/v1`);
  const hit = await caches.default.match(key);
  if (hit) { try { return await hit.json(); } catch (_) {} }
  const [cases, adopt] = await Promise.all([loadCases(), adoptStats(waitUntil).catch(() => null)]);
  const now = Date.now(), D = 86400e3;
  const active = cases.filter((c) => c.status === "searching");
  const sp = (l, s) => l.filter((c) => c.species === s).length;
  const lost30 = cases.filter((c) => c.lost_at && now - Date.parse(c.lost_at) <= 30 * D && Date.parse(c.lost_at) <= now);
  const found = cases.filter((c) => c.status === "found");
  const foundDays = found.filter((c) => c.found_at && c.lost_at).map((c) => (Date.parse(c.found_at) - Date.parse(c.lost_at)) / D).filter((x) => x >= 0).sort((a, b) => a - b);
  const median = foundDays.length >= 5 ? Math.round(foundDays[Math.floor(foundDays.length / 2)]) : null;
  const age = { w1: 0, m1: 0, m3: 0, older: 0 };
  for (const c of active) { const d = (now - Date.parse(c.lost_at)) / D; if (d <= 7) age.w1++; else if (d <= 30) age.m1++; else if (d <= 90) age.m3++; else age.older++; }
  // 近 6 個月每月走失數（依走失日期）
  const months = [];
  for (let i = 5; i >= 0; i--) { const d = tw(now); d.setUTCDate(1); d.setUTCMonth(d.getUTCMonth() - i); months.push({ ym: `${d.getUTCFullYear()}/${d.getUTCMonth() + 1}`, y: d.getUTCFullYear(), m: d.getUTCMonth(), dog: 0, cat: 0 }); }
  for (const c of cases) { if (!c.lost_at) continue; const d = tw(Date.parse(c.lost_at)); const row = months.find((x) => x.y === d.getUTCFullYear() && x.m === d.getUTCMonth()); if (row) row[c.species === "cat" ? "cat" : "dog"]++; }
  const byCity = CITIES.map((city) => {
    const a = active.filter((c) => normCity(c.lost_city) === city);
    const ad = adopt && adopt.byCity[city] ? adopt.byCity[city] : { dog: 0, cat: 0 };
    return { city, lost: a.length, lostDog: sp(a, "dog"), lostCat: sp(a, "cat"), adoptDog: ad.dog, adoptCat: ad.cat };
  });
  const out = {
    updated: new Date(now).toISOString(), updatedTw: twDate(now),
    lost: { active: active.length, dog: sp(active, "dog"), cat: sp(active, "cat"), fromMoa: active.filter((c) => c.source === "moa").length,
      fromSite: active.filter((c) => c.source !== "moa").length, last30: lost30.length, last30Dog: sp(lost30, "dog"), last30Cat: sp(lost30, "cat"),
      age, found: found.length, foundMedianDays: median, months: months.map(({ ym, dog, cat }) => ({ ym, dog, cat })) },
    adopt: adopt ? { total: adopt.total, dog: adopt.dog, cat: adopt.cat, newLast7Days: adopt.recent7, young: adopt.child, sterilized: adopt.ster, shelters: adopt.shelters } : null,
    byCity,
    sources: ["汪喵回家協尋案件（飼主與民眾登記）", "農業部寵物登記管理資訊網「遺失啟事」", "農業部「動物認領養」開放資料"],
    license: "CC BY 4.0（引用請註明：汪喵回家 wangmiaotw.com）",
  };
  const body = JSON.stringify(out);
  const p = caches.default.put(key, new Response(body, { headers: { "content-type": "application/json", "cache-control": "public, max-age=3600" } }));
  if (waitUntil) waitUntil(p); else await p;
  return out;
}

const STYLE = `<style>.kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:12px;margin:14px 0}
.kpi{background:#fff;border-radius:18px;padding:14px 16px}.kpi b{display:block;font-size:28px;line-height:1.2}.kpi small{color:var(--mute)}
table{border-collapse:collapse;width:100%;background:#fff;border-radius:16px;overflow:hidden;margin-top:10px}td,th{padding:8px 10px;border-bottom:1px solid var(--line);text-align:right;font-size:15px}td:first-child,th:first-child{text-align:left}th{color:var(--mute);font-weight:700}
.bar{display:inline-block;height:10px;border-radius:5px;background:var(--coral);vertical-align:middle;margin-left:6px}.bar.c{background:#7A8FC9}
.src{color:var(--mute);font-size:14px}</style>`;

export async function statsPage(waitUntil) {
  let s;
  try { s = await compute(waitUntil); } catch (_) { return resp(shell({ title: `台灣走失狗貓統計｜${NAME}`, desc: "資料暫時讀不到，請稍後再試。", canonical: `${SITE}stats`, body: "<h1>台灣走失狗貓統計</h1><p>資料暫時讀不到，請稍後再試。</p>", noindex: true }), 503, 60); }
  const L = s.lost, A = s.adopt;
  const title = `台灣走失狗貓與收容所領養統計（${s.updatedTw} 更新）｜${NAME}`;
  const desc = `全台目前有 ${n(L.active)} 隻狗貓在協尋中（狗 ${n(L.dog)}、貓 ${n(L.cat)}），近 30 天新增走失 ${n(L.last30)} 件${A ? `；公立收容所有 ${n(A.total)} 隻狗貓等待領養` : ""}。依縣市整理，每天自動更新。`;
  const maxM = Math.max(1, ...L.months.map((m) => m.dog + m.cat));
  const topLost = [...s.byCity].sort((a, b) => b.lost - a.lost).slice(0, 5).filter((x) => x.lost);
  const topAdopt = [...s.byCity].sort((a, b) => (b.adoptDog + b.adoptCat) - (a.adoptDog + a.adoptCat)).slice(0, 5);
  const body = `${STYLE}<h1>台灣走失狗貓與收容所領養統計</h1>
<p class="lede">整理全台正在協尋的走失狗貓，以及公立收容所等待領養的毛孩。資料每天自動更新，最後更新：${esc(s.updatedTw)}。</p>
<h2>重點數字</h2>
<div class="kpis">
<div class="kpi"><b>${n(L.active)}</b><small>目前協尋中的狗貓</small></div>
<div class="kpi"><b>${n(L.dog)} / ${n(L.cat)}</b><small>其中狗 / 貓</small></div>
<div class="kpi"><b>${n(L.last30)}</b><small>近 30 天新增走失</small></div>
${A ? `<div class="kpi"><b>${n(A.total)}</b><small>收容所等待領養（狗 ${n(A.dog)}、貓 ${n(A.cat)}）</small></div>
<div class="kpi"><b>${n(A.newLast7Days)}</b><small>近 7 天收容所新公告</small></div>
<div class="kpi"><b>${n(A.shelters)}</b><small>有待領養毛孩的公立收容所</small></div>` : ""}
</div>
<h2>重點整理</h2><ul>
<li>目前全台有 ${n(L.active)} 隻走失狗貓在協尋中，狗佔 ${pct(L.dog, L.active)}%、貓佔 ${pct(L.cat, L.active)}%。</li>
${topLost.length ? `<li>協尋中最多的縣市：${topLost.map((x) => `${x.city}（${n(x.lost)}）`).join("、")}。</li>` : ""}
<li>協尋中的毛孩有 ${pct(L.age.older + L.age.m3, L.active)}% 已經走失超過 30 天，長期協尋很常見，不要太早放棄。</li>
${A ? `<li>公立收容所共有 ${n(A.total)} 隻狗貓等待領養，其中幼年 ${n(A.young)} 隻、已結紮 ${n(A.sterilized)} 隻。待領養最多的縣市：${topAdopt.map((x) => `${x.city}（${n(x.adoptDog + x.adoptCat)}）`).join("、")}。</li>` : ""}
<li>走失的毛孩常被好心人送到收容所，所以走失後要同時查收容所公告；汪喵回家每天自動比對。</li>
</ul>
<h2>近 6 個月每月走失數</h2>
<table><tr><th>月份</th><th>狗</th><th>貓</th><th>合計</th></tr>
${L.months.map((m) => `<tr><td>${esc(m.ym)}</td><td>${n(m.dog)}</td><td>${n(m.cat)}</td><td>${n(m.dog + m.cat)}<span class="bar" style="width:${Math.round(((m.dog + m.cat) / maxM) * 80)}px"></span></td></tr>`).join("")}
</table>
<p class="src">依走失日期統計；當月數字會隨新的登記持續增加。汪喵回家從 2026 年秋天開始大量收錄（含農業部遺失申報），較早月份的數字偏少，不代表當時走失比較少。</p>
<h2>協尋中的毛孩走失多久了</h2>
<table><tr><th>走失時間</th><th>隻數</th><th>比例</th></tr>
<tr><td>7 天內</td><td>${n(L.age.w1)}</td><td>${pct(L.age.w1, L.active)}%</td></tr>
<tr><td>8～30 天</td><td>${n(L.age.m1)}</td><td>${pct(L.age.m1, L.active)}%</td></tr>
<tr><td>31～90 天</td><td>${n(L.age.m3)}</td><td>${pct(L.age.m3, L.active)}%</td></tr>
<tr><td>超過 90 天</td><td>${n(L.age.older)}</td><td>${pct(L.age.older, L.active)}%</td></tr></table>
<h2>各縣市：協尋中與待領養</h2>
<table><tr><th>縣市</th><th>協尋中的狗</th><th>協尋中的貓</th><th>待領養的狗</th><th>待領養的貓</th></tr>
${s.byCity.map((x) => `<tr><td><a href="${SITE}l/${encodeURIComponent(x.city)}">${x.city}</a></td><td>${n(x.lostDog)}</td><td>${n(x.lostCat)}</td><td><a href="${SITE}adopt/${encodeURIComponent(x.city)}/${encodeURIComponent("狗")}">${n(x.adoptDog)}</a></td><td><a href="${SITE}adopt/${encodeURIComponent(x.city)}/${encodeURIComponent("貓")}">${n(x.adoptCat)}</a></td></tr>`).join("")}
</table>
<h2>想幫忙的話</h2><ul>
<li>毛孩走失了：<a href="${SITE}#/new">免費登記協尋</a>，自動做協尋海報、接收目擊回報，每天比對收容所。</li>
<li>看到或撿到狗貓：<a href="${SITE}#/found/new">登記通報</a>，或到附近動物醫院免費掃晶片。</li>
<li>想養狗養貓：<a href="${SITE}adopt/">看全台收容所待領養的毛孩</a>，依縣市、品種找，附收容所電話；也可以看<a href="${SITE}rehome/">民眾送養</a>。</li>
<li>不能養了想幫毛孩找新家：到<a href="${SITE}rehome/">民眾送養</a>免費刊登，由你親自挑選領養人。</li></ul>
<h2>資料來源與引用</h2>
<p class="src">資料來源：${s.sources.map(esc).join("；")}。協尋數字只包含登記在汪喵回家與農業部遺失申報的案件，不代表全台實際走失數。<br>
歡迎媒體、研究與 AI 助理引用，請註明「資料來源：汪喵回家 wangmiaotw.com」（CC BY 4.0）。機器可讀版本：<a href="${SITE}stats.json">stats.json</a>。媒體與合作資料：<a href="${SITE}press">關於汪喵回家</a>。</p>`;
  const jsonld = [{ "@context": "https://schema.org", "@type": "Dataset", name: "台灣走失狗貓與收容所待領養統計", description: desc, url: `${SITE}stats`, inLanguage: "zh-Hant",
    creator: { "@type": "Organization", name: NAME, url: SITE }, license: "https://creativecommons.org/licenses/by/4.0/", isAccessibleForFree: true, dateModified: s.updated,
    spatialCoverage: { "@type": "Place", name: "臺灣" }, keywords: ["走失狗", "走失貓", "寵物協尋", "收容所", "領養", "台灣", "統計"],
    variableMeasured: ["協尋中的狗貓數量", "近 30 天新增走失數", "每月走失數", "收容所待領養狗貓數量", "各縣市協尋與待領養數量"],
    distribution: [{ "@type": "DataDownload", encodingFormat: "application/json", contentUrl: `${SITE}stats.json` }] }];
  return resp(shell({ title, desc, canonical: `${SITE}stats`, body, jsonld }), 200, 1800);
}

export async function statsJson(waitUntil) {
  try { const s = await compute(waitUntil); return new Response(JSON.stringify(s, null, 1), { headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=1800", "access-control-allow-origin": "*" } }); }
  catch (_) { return new Response('{"error":"unavailable"}', { status: 503, headers: { "content-type": "application/json" } }); }
}

export async function pressPage(waitUntil) {
  let s = null; try { s = await compute(waitUntil); } catch (_) {}
  const L = s && s.lost, A = s && s.adopt;
  const title = `關於汪喵回家：台灣免費的走失狗貓協尋與收容所領養平台｜媒體與合作資料`;
  const desc = `汪喵回家（wangmiaotw.com）是台灣免費的走失狗貓協尋平台，也整理全台公立收容所待領養的狗貓。提供協尋登記、目擊回報、AI 照片比對、每天比對收容所，網站、iPhone App 都能用。`;
  const body = `<h1>關於汪喵回家</h1>
<p class="lede">汪喵回家是台灣免費的走失狗貓協尋平台，也是一站看完全台公立收容所待領養狗貓的地方。我們把散在各處的協尋力量集中起來，陪走失的毛孩回家，也幫收容所的毛孩找到新家。</p>
<h2>一句話介紹</h2>
<p>汪喵回家（wangmiaotw.com）是台灣免費的走失狗貓協尋與收容所領養平台：飼主可以免費登記協尋、自動產生協尋海報；民眾看到或撿到狗貓可以回報；系統每天比對全台公立收容所與農業部遺失申報，並提供 AI 照片比對；想養狗養貓的人可以依縣市、品種找收容所的毛孩。</p>
${s ? `<h2>現在的數字</h2><ul>
<li>目前協尋中的狗貓：${n(L.active)} 隻（狗 ${n(L.dog)}、貓 ${n(L.cat)}）</li>
<li>近 30 天新增走失：${n(L.last30)} 件</li>
${A ? `<li>全台公立收容所等待領養：${n(A.total)} 隻（狗 ${n(A.dog)}、貓 ${n(A.cat)}），來自 ${n(A.shelters)} 間收容所</li>` : ""}
<li>資料每天自動更新，完整統計：<a href="${SITE}stats">台灣走失狗貓與收容所領養統計</a>（最後更新 ${esc(s.updatedTw)}）</li></ul>` : ""}
<h2>可以做什麼</h2><ul>
<li><b>免費登記走失協尋</b>：填好資料就有協尋頁和附 QR Code 的協尋海報，可分享到 LINE、FB。</li>
<li><b>目擊回報與拾獲通報</b>：看到或撿到毛孩的人可以直接回報，位置標在地圖上並通知飼主；也可以直接打電話給飼主。</li>
<li><b>每天比對全台收容所</b>：比對公立收容所新公告的狗貓和農業部寵物登記網的遺失申報。</li>
<li><b>AI 照片比對</b>：只有一張照片也能找，在手機上比對走失協尋、拾獲通報和收容所的毛孩。</li>
<li><b>收容所領養</b>：全台公立收容所待領養的狗貓，依縣市、品種、收容所查看，附收容所電話與地址。<a href="${SITE}adopt/">看待領養的毛孩</a></li>
<li><b>各縣市走失頁</b>：每個縣市、鄉鎮市區都有一頁，列出當地正在找的毛孩、動保單位電話與收容所。</li>
<li><b>附近走失通知</b>：設定家的位置，附近有毛孩走失時通知你（晚上不推播，不打擾）。</li></ul>
<h2>初衷</h2>
<p>走失協尋貼文很快就被社群洗掉，線索也散在不同的社團和群組裡。汪喵回家只是幫忙集中力量的網站：看到毛孩可以在網站回報，也可以直接打電話給飼主，線索一律交給飼主。完全免費、不收手續費、不賣資料。</p>
<h2>在哪裡用</h2><ul>
<li>網站：<a href="${SITE}">wangmiaotw.com</a>（手機、電腦都能用）</li>
<li>iPhone App：<a href="${SITE}app">App Store 搜尋「汪喵回家」</a></li>
<li>Facebook、Instagram、Threads：@wangmiaotw</li></ul>
<h2>給媒體與合作單位</h2><ul>
<li>歡迎引用網站上的統計數字，請註明「資料來源：汪喵回家 wangmiaotw.com」。</li>
<li>動保單位、收容所、動物醫院、寵物店家想合作（協尋資訊交流、張貼協尋 QR Code 立牌等），歡迎來信。</li>
<li>Logo：<a href="${SITE}icon-512.png">icon-512.png</a>；分享圖：<a href="${SITE}og.png">og.png</a></li>
<li>聯絡信箱：<a href="mailto:service@wangmiaotw.com">service@wangmiaotw.com</a></li></ul>
<h2>常見問題</h2>
<div class="faq">
<details><summary>汪喵回家要錢嗎？</summary><p>完全免費，不收手續費、不賣資料。自稱撿到毛孩卻要求先匯款的，多半是詐騙。</p></details>
<details><summary>汪喵回家的資料從哪裡來？</summary><p>飼主和民眾在網站登記的協尋、目擊與拾獲通報，加上農業部寵物登記管理資訊網的遺失申報，以及農業部「動物認領養」開放資料。</p></details>
<details><summary>可以在汪喵回家領養狗貓嗎？</summary><p>汪喵回家整理全台公立收容所待領養的狗貓，可以依縣市、品種找，每隻都附收容所電話和地址；領養手續由收容所辦理。</p></details>
<details><summary>汪喵回家跟 FB 協尋社團有什麼不同？</summary><p>社團貼文很快被洗下去，汪喵回家的協尋資料會一直留著並依縣市、鄉鎮分類，路人可以直接回報，系統也會每天比對收容所。兩者可以一起用。</p></details>
</div>`;
  const jsonld = [{ "@context": "https://schema.org", "@type": "AboutPage", name: "關於汪喵回家", url: `${SITE}press`, inLanguage: "zh-Hant",
    mainEntity: { "@type": "Organization", name: NAME, alternateName: ["WangMiao Home", "wangmiaotw"], url: SITE, logo: `${SITE}icon-512.png`, email: "service@wangmiaotw.com",
      description: desc, areaServed: { "@type": "Country", name: "臺灣" },
      knowsAbout: ["走失狗協尋", "走失貓協尋", "寵物協尋", "收容所領養", "認養狗貓", "寵物晶片", "AI 照片比對"],
      sameAs: ["https://www.facebook.com/wangmiaotw", "https://www.instagram.com/wangmiaotw/", "https://www.threads.com/@wangmiaotw", "https://apps.apple.com/tw/app/id6827632980"] } },
    { "@context": "https://schema.org", "@type": "FAQPage", mainEntity: [
      ["汪喵回家要錢嗎？", "完全免費，不收手續費、不賣資料。"],
      ["可以在汪喵回家領養狗貓嗎？", "汪喵回家整理全台公立收容所待領養的狗貓，可以依縣市、品種找，每隻都附收容所電話和地址；領養手續由收容所辦理。"],
      ["汪喵回家的資料從哪裡來？", "飼主和民眾登記的協尋、目擊與拾獲通報，農業部寵物登記管理資訊網的遺失申報，以及農業部動物認領養開放資料。"]].map(([q, a]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a } })) }];
  return resp(shell({ title, desc, canonical: `${SITE}press`, body, jsonld }), 200, 3600);
}

// 英文說明頁（/en）：給在台灣的外國人，以及用英文發問的 AI 助理／搜尋引擎。內容是固定的事實說明，不含即時資料。
export async function enPage() {
  const title = "WangMiao Home (汪喵回家) — Free lost dog & cat search platform in Taiwan";
  const desc = "Lost your dog or cat in Taiwan? WangMiao Home (wangmiaotw.com) is a free platform to post a lost-pet alert, receive sighting reports, check public shelters every day, and browse shelter animals for adoption. No fees.";
  const faq = [
    ["My dog or cat is lost in Taiwan. What should I do?", "Search the area where your pet went missing right away, calmly and without chasing. Post a free lost-pet alert on WangMiao Home (wangmiaotw.com) so neighbours can report sightings. Call the local animal protection office or shelter (national animal protection hotline: 1959). If your pet has a microchip, report it as lost in the Ministry of Agriculture pet registration system."],
    ["Is WangMiao Home free?", "Yes. Posting an alert, reporting a sighting and using the app are all free. There are no service fees and data is not sold. Anyone who claims to have found your pet and asks you to transfer money first is very likely a scammer."],
    ["I found or saw a stray dog or cat in Taiwan. How do I report it?", "Do not chase the animal. Take a photo, note the time and place, then report a sighting or register a found pet on wangmiaotw.com. Your report goes directly to the owner. A vet clinic or shelter can scan for a microchip for free."],
    ["Can I adopt a dog or cat through WangMiao Home?", "The site lists dogs and cats waiting for adoption in public shelters across Taiwan, searchable by city, breed and shelter, with each shelter's phone number and address. The adoption itself is handled by the shelter."],
    ["Is the site available in English?", "The site and app are in Traditional Chinese. This page summarises how it works in English; a browser translator works well for the rest. Owners can write their alert in any language."],
  ];
  const body = `<h1>WangMiao Home (汪喵回家)</h1>
<p class="lede">A free platform in Taiwan for finding lost dogs and cats, and for browsing public-shelter animals waiting for adoption. Website: <a href="${SITE}">wangmiaotw.com</a>. iPhone app: search “汪喵回家” on the App Store.</p>
<h2>What it does</h2><ul>
<li><b>Post a lost-pet alert for free</b> — with photos, location and contact details. A printable poster is generated automatically. <a href="${SITE}#/new">Post an alert</a></li>
<li><b>Sighting reports</b> — anyone who sees the animal can report where and when; the report goes straight to the owner.</li>
<li><b>Daily shelter matching</b> — every day the system compares alerts with animals taken in by public shelters across Taiwan and with lost-pet filings in the Ministry of Agriculture registry.</li>
<li><b>Photo matching</b> — finds animals that look similar to yours among found pets and shelter intakes.</li>
<li><b>Adoption listings</b> — dogs and cats in public shelters, by city, breed and shelter. <a href="${SITE}adopt/">Browse adoptable animals</a></li>
</ul>
<h2>Why it exists</h2>
<p>Lost-pet posts on social media get buried within hours. WangMiao Home keeps every alert in one place, sorted by city and district, so the help that is scattered everywhere can be gathered together. It is only a place to gather information: clues always go directly to the owner.</p>
<h2>If your pet is lost in Taiwan</h2><ol>
<li>Go back to where your pet went missing. Bring familiar treats, call softly, and do not chase.</li>
<li>Post a free alert at <a href="${SITE}#/new">wangmiaotw.com</a>.</li>
<li>Call the local animal protection office and shelter. The national animal protection hotline is <b>1959</b>.</li>
<li>If your pet is microchipped, report it as lost in the Ministry of Agriculture pet registration system.</li>
</ol>
<h2>Useful pages (in Chinese)</h2><ul>
<li><a href="${SITE}l/">Lost pets by city and district</a></li>
<li><a href="${SITE}g/">Guides: what to do when a pet is lost or found</a></li>
<li><a href="${SITE}adopt/">Shelter animals for adoption</a></li>
<li><a href="${SITE}stats">Statistics on lost pets and shelter adoption in Taiwan</a></li>
<li><a href="${SITE}press">About / press (中文)</a></li>
</ul>
<h2>Frequently asked questions</h2>
<div class="faq">${faq.map(([q, a]) => `<details open><summary>${q}</summary><p>${a}</p></details>`).join("")}</div>
<p>Contact: <a href="mailto:service@wangmiaotw.com">service@wangmiaotw.com</a> · Facebook / Instagram / Threads: @wangmiaotw</p>`;
  const jsonld = [{ "@context": "https://schema.org", "@type": "AboutPage", name: title, url: `${SITE}en`, inLanguage: "en",
    mainEntity: { "@type": "Organization", name: "WangMiao Home", alternateName: [NAME, "wangmiaotw"], url: SITE, logo: `${SITE}icon-512.png`, email: "service@wangmiaotw.com",
      description: desc, areaServed: { "@type": "Country", name: "Taiwan" },
      knowsAbout: ["lost dog search", "lost cat search", "lost pets in Taiwan", "animal shelter adoption in Taiwan", "pet microchip"],
      sameAs: ["https://www.facebook.com/wangmiaotw", "https://www.instagram.com/wangmiaotw/", "https://www.threads.com/@wangmiaotw", "https://apps.apple.com/tw/app/id6827632980"] } },
    { "@context": "https://schema.org", "@type": "FAQPage", inLanguage: "en", mainEntity: faq.map(([q, a]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a } })) }];
  return resp(shell({ title, desc, canonical: `${SITE}en`, body, jsonld }).replace('<html lang="zh-Hant">', '<html lang="en">'), 200, 86400);
}

// 汪喵回家 — 給搜尋引擎看的頁面（Cloudflare Pages Functions，即時產生）
//   /p/<案件>       每一隻走失毛孩一頁：照片、特徵、走失地區、日期（Google 搜得到）
//   /l/<縣市>       這個縣市正在協尋的毛孩
//   /g/<指南>       協尋指南、毛孩小學堂的靜態文章（lib/guides.js）
//   /sitemap.xml    所有協尋中的毛孩、縣市頁、指南、待領養毛孩（lib/adopt.js）
// 只讀公開資料（publishable key，本來就公開在網頁裡）。
import { GUIDE_IDS } from "./guides.js";
import { adoptUrls, CITIES as ACITIES } from "./adopt.js";
const SUPABASE_URL = "https://nopyhfpaykkiieudvoko.supabase.co";
const ANON_KEY = "sb_publishable_WCeVQIAPH0UEEzhTwovqkg_lJ8Qjydb";
const SITE = "https://wangmiaotw.com/";
const NAME = "汪喵回家";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const CITIES = ["臺北市","新北市","桃園市","臺中市","臺南市","高雄市","基隆市","新竹市","新竹縣","苗栗縣","彰化縣","南投縣","雲林縣","嘉義市","嘉義縣","屏東縣","宜蘭縣","花蓮縣","臺東縣","澎湖縣","金門縣","連江縣"];
const SP = { dog: ["狗", "尋狗啟事"], cat: ["貓", "尋貓啟事"] };
const SEX = { male: "公", female: "母" };
const SIZE = { small: "小型", medium: "中型", large: "大型" };

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const okImg = (u) => typeof u === "string" && /^https:\/\/nopyhfpaykkiieudvoko\.supabase\.co\/storage\/v1\/object\/public\/photos\/[^\s'"()<>\\]+$/.test(u) ? u : "";
const thumb = (u) => /\.jpg$/.test(u) && !/_t\.jpg$/.test(u) ? u.replace(/\.jpg$/, "_t.jpg") : u;
const twDate = (ts) => { try { const d = new Date(new Date(ts).getTime() + 8 * 3600e3); return `${d.getUTCFullYear()}/${d.getUTCMonth() + 1}/${d.getUTCDate()}`; } catch (_) { return ""; } };
const days = (ts) => { const a = new Date(new Date(ts).getTime() + 8 * 3600e3), b = new Date(Date.now() + 8 * 3600e3);
  return Math.max(1, Math.round((Date.UTC(b.getUTCFullYear(), b.getUTCMonth(), b.getUTCDate()) - Date.UTC(a.getUTCFullYear(), a.getUTCMonth(), a.getUTCDate())) / 864e5) + 1); };
const normCity = (c) => String(c || "").replace(/^台/, "臺");

async function q(path) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: { apikey: ANON_KEY, Accept: "application/json" }, cf: { cacheTtl: 30 } });   // 站長下架的案件 30 秒內就不再出現
  if (!r.ok) throw new Error("db " + r.status);
  return r.json();
}
const resp = (body, status = 200, type = "text/html; charset=utf-8", maxAge = 60) => new Response(body, { status, headers: {
  "content-type": type, "cache-control": `public, max-age=${maxAge}`, "x-content-type-options": "nosniff" } });

const CSS = `:root{--ink:#2B2326;--mute:#6F6468;--red:#B8335A;--bg:#FDF6F8;--card:#fff;--line:#EADDE2}
*{box-sizing:border-box}body{margin:0;font-family:system-ui,"PingFang TC","Noto Sans TC","Microsoft JhengHei",sans-serif;background:var(--bg);color:var(--ink);line-height:1.6}
a{color:var(--red)}header{display:flex;align-items:center;gap:10px;padding:14px 16px;max-width:960px;margin:0 auto}header a{display:flex;align-items:center;gap:8px;text-decoration:none;color:var(--ink);font-weight:800;font-size:20px}header img{width:34px;height:34px}
main{max-width:960px;margin:0 auto;padding:0 16px 40px}h1{font-size:26px;line-height:1.3;margin:8px 0 6px}.meta{color:var(--mute);margin:0 0 14px}
.hero{display:grid;gap:18px}@media(min-width:760px){.hero{grid-template-columns:1fr 1fr}}.ph{width:100%;aspect-ratio:1;object-fit:cover;border-radius:20px;background:#eee}
.card{background:var(--card);border-radius:20px;padding:16px 18px;box-shadow:0 10px 24px -18px rgba(90,30,50,.35)}dl{display:grid;grid-template-columns:auto 1fr;gap:6px 14px;margin:0}dt{color:var(--mute);font-weight:700}dd{margin:0}
.btn{display:block;text-align:center;background:var(--red);color:#fff;text-decoration:none;font-weight:800;padding:14px;border-radius:16px;margin-top:12px}.btn.ghost{background:#fff;color:var(--ink);border:1.5px solid var(--line)}
.tip{background:#FFF6DC;border-radius:14px;padding:10px 14px;margin-top:12px;font-size:15px}.badge{display:inline-block;background:var(--red);color:#fff;border-radius:99px;padding:2px 10px;font-size:13px;font-weight:800}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;margin-top:12px}.it{display:block;text-decoration:none;color:var(--ink);background:var(--card);border-radius:16px;overflow:hidden}.it img,.it .np{width:100%;aspect-ratio:1;object-fit:cover;display:block;background:#F1E8EB}.it b{display:block;padding:8px 10px 0}.it small{display:block;padding:0 10px 10px;color:var(--mute)}
h2{font-size:20px;margin:28px 0 4px}nav.cities{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}nav.cities a{background:#fff;border-radius:99px;padding:6px 12px;text-decoration:none;color:var(--ink);font-size:14px}footer{color:var(--mute);font-size:13px;text-align:center;padding:24px 16px}`;

function shell({ title, desc, canonical, image, body, noindex = false, jsonld = null }) {
  const img = okImg(image) || SITE + "og.png?v=2";
  return `<!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="apple-itunes-app" content="app-id=6827632980">
<title>${esc(title)}</title><meta name="description" content="${esc(desc)}">${noindex ? '<meta name="robots" content="noindex">' : ""}
<link rel="canonical" href="${esc(canonical)}"><link rel="icon" href="${SITE}icon.svg" type="image/svg+xml">
<meta property="og:type" content="article"><meta property="og:site_name" content="${NAME}"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}"><meta property="og:image" content="${esc(img)}"><meta property="og:url" content="${esc(canonical)}"><meta property="og:locale" content="zh_TW"><meta name="twitter:card" content="summary_large_image">
${jsonld ? `<script type="application/ld+json">${JSON.stringify(jsonld).replace(/</g, "\\u003c")}</script>` : ""}
<style>${CSS}</style></head><body>
<header><a href="${SITE}"><img src="${SITE}icon.svg" alt="">${NAME}</a></header><main>${body}</main>
<footer>${NAME}｜全台走失狗貓協尋平台・免費・不收手續費<br><a href="${SITE}">回首頁</a>・<a href="${SITE}l/">各縣市走失毛孩</a>・<a href="${SITE}g/">協尋指南</a>・<a href="${SITE}adopt/">領養</a>・<a href="${SITE}app">下載 App</a></footer></body></html>`;
}

function itemHTML(c) {
  const ph = okImg((c.photos || [])[0]);
  return `<a class="it" href="${SITE}p/${c.id}">${ph ? `<img loading="lazy" src="${esc(thumb(ph))}" alt="${esc(c.name)}">` : '<div class="np"></div>'}<b>${esc(c.name)}</b><small>${esc((c.lost_city || "") + (c.lost_district || ""))}・走失第 ${days(c.lost_at)} 天</small></a>`;
}

export async function casePage(id) {
  id = String(id || "").replace(/\.html$/, "");
  if (!UUID.test(id)) return notFound();
  let c;
  try { c = (await q(`cases_public?id=eq.${id}&select=id,species,name,status,breed,sex,size,colour,features,collar_desc,temperament,has_chip,lost_city,lost_district,lost_place,lost_at,photos,reward,contact_phone,source,notes,age_text&limit=1`))[0]; }
  catch (_) { return resp(shell({ title: NAME, desc: "", canonical: `${SITE}p/${id}`, body: `<p>暫時連不上資料，請<a href="${SITE}#/case/${id}">打開協尋頁</a>。</p>`, noindex: true }), 503, undefined, 0); }
  if (!c) return resp(shell({ title: `${NAME}｜找不到這個頁面`, desc: "這個協尋可能已經結束。", canonical: `${SITE}p/${id}`, body: `<h1>這個協尋已經不在了</h1><p>可能已經找到或結案了。<a href="${SITE}">回首頁看其他正在找的毛孩</a></p>`, noindex: true }), 404, undefined, 300);
  const [unit, poster] = SP[c.species] || SP.dog;
  const area = `${c.lost_city || ""}${c.lost_district || ""}`;
  const searching = c.status === "searching";
  const look = [c.breed, SEX[c.sex], c.size ? SIZE[c.size] : "", c.colour].filter(Boolean).join("・");
  const kind = [c.colour, c.breed].filter(Boolean).join("") || unit;   // 例：全白米克斯、黑色貴賓（別人會這樣搜）
  const title = searching ? `【${poster}】${c.name}｜${area}走失的${kind}・${twDate(c.lost_at)}｜${NAME}` : c.status === "found" ? `${c.name} 已經找到了｜${NAME}` : `${c.name}（協尋已結束）｜${NAME}`;
  const desc = [`${twDate(c.lost_at)} 在${area}${c.lost_place || ""}走失的${look || unit}「${c.name}」`, c.features || "", c.collar_desc || "", Number(c.reward) > 0 && searching ? `尋獲獎金 NT$${Number(c.reward).toLocaleString("en-US")}` : "", searching ? "看到請不要追，拍照記下時間地點，聯絡飼主。" : ""].filter(Boolean).join("。").slice(0, 160);
  const more = (c.photos || []).slice(1, 6).map(okImg).filter(Boolean);
  const distUrl = c.lost_district ? `${SITE}l/${encodeURIComponent(c.lost_city)}/${encodeURIComponent(c.lost_district)}` : "";
  const ph = okImg((c.photos || [])[0]);
  const tel = searching && c.source !== "moa" && c.contact_phone ? String(c.contact_phone).replace(/[^\d+#]/g, "") : "";
  let others = [];
  try { others = (await q(`cases_public?status=eq.searching&lost_city=eq.${encodeURIComponent(c.lost_city)}&id=neq.${id}&photos=not.eq.%7B%7D&select=id,name,lost_city,lost_district,lost_at,photos&order=last_activity.desc&limit=8`)) || []; } catch (_) {}
  const body = `${searching ? `<span class="badge">走失第 ${days(c.lost_at)} 天</span>` : ""}
<h1>${esc(searching ? `${poster}｜${c.name}` : title.replace(`｜${NAME}`, ""))}</h1>
<p class="meta">📍 ${esc(area)}${c.lost_place ? "　" + esc(c.lost_place) : ""}　走失於 ${esc(twDate(c.lost_at))}${c.source === "moa" ? "　（農業部寵物登記網遺失申報）" : ""}</p>
<div class="hero">${ph ? `<img class="ph" src="${esc(ph)}" alt="${esc(`${area}走失的${kind}「${c.name}」`)}">` : ""}
<div class="card"><dl>${look ? `<dt>特徵</dt><dd>${esc(look)}</dd>` : ""}${c.features ? `<dt>辨識</dt><dd>${esc(c.features)}</dd>` : ""}${c.collar_desc ? `<dt>項圈</dt><dd>${esc(c.collar_desc)}</dd>` : ""}${c.temperament ? `<dt>個性</dt><dd>${esc(c.temperament)}</dd>` : ""}${c.age_text ? `<dt>年紀</dt><dd>${esc(c.age_text)}</dd>` : ""}<dt>晶片</dt><dd>${c.has_chip ? "有" : "無／不確定"}</dd>${c.reward ? `<dt>獎金</dt><dd>NT$${Number(c.reward).toLocaleString("en-US")}</dd>` : ""}</dl>
${searching ? `<p class="tip">看到${esc(c.name)}：<b>不要叫、不要追</b>，拍照記下時間地點，聯絡飼主。</p>` : ""}
${tel ? `<a class="btn" href="tel:${esc(tel)}">📞 看到牠了，打給飼主</a>` : ""}
<a class="btn ${tel ? "ghost" : ""}" href="${SITE}#/case/${id}">打開完整協尋頁（地圖、海報、分享）</a></div></div>
${searching && c.notes ? `<h2>走失經過</h2><p>${esc(String(c.notes).slice(0, 600))}</p>` : ""}
${searching && more.length ? `<h2>${esc(c.name)}的其他照片</h2><div class="grid">${more.map((u, i) => `<span class="it"><img loading="lazy" src="${esc(thumb(u))}" alt="${esc(`${area}走失的${kind}${c.name} 照片 ${i + 2}`)}"></span>`).join("")}</div>` : ""}
${searching ? `<p class="meta" style="margin-top:18px">住在${esc(area)}附近嗎？出門時幫忙多看一眼。${distUrl ? `<a href="${distUrl}">看${esc(area)}所有走失毛孩</a>・` : ""}<a href="${SITE}g/see-stray">看到疑似走失的毛孩該怎麼做</a></p>` : ""}
${others.length ? `<h2>${esc(c.lost_city)}其他正在找的毛孩</h2><div class="grid">${others.map(itemHTML).join("")}</div><p><a href="${SITE}l/${encodeURIComponent(c.lost_city)}">看${esc(c.lost_city)}全部走失毛孩 →</a></p>` : ""}`;
  const jsonld = { "@context": "https://schema.org", "@graph": [
    { "@type": "WebPage", name: title, description: desc, ...(ph ? { image: ph } : {}), datePublished: c.lost_at, url: `${SITE}p/${id}` },
    { "@type": "BreadcrumbList", itemListElement: [
      { "@type": "ListItem", position: 1, name: NAME, item: SITE },
      { "@type": "ListItem", position: 2, name: `${c.lost_city}走失毛孩`, item: `${SITE}l/${encodeURIComponent(c.lost_city)}` },
      ...(distUrl ? [{ "@type": "ListItem", position: 3, name: `${c.lost_district}`, item: distUrl }] : []),
      { "@type": "ListItem", position: distUrl ? 4 : 3, name: c.name, item: `${SITE}p/${id}` }] }] };
  return resp(shell({ title, desc, canonical: `${SITE}p/${id}`, image: ph, body, noindex: !searching, jsonld }));
}

const notFound = () => resp(shell({ title: `${NAME}｜找不到這個頁面`, desc: "", canonical: SITE, body: `<h1>找不到這個頁面</h1><p>網址可能打錯了，或內容已經移除。</p><a class="btn" href="${SITE}">回汪喵回家首頁</a>`, noindex: true }), 404, undefined, 300);
const GUIDE_LINKS = `<h2>走失了怎麼辦？</h2><p><a href="${SITE}g/dog-lost">狗走失怎麼辦：黃金 48 小時</a>・<a href="${SITE}g/cat-lost">貓走失怎麼找</a>・<a href="${SITE}g/shelter-search">怎麼查收容所</a>・<a href="${SITE}g/found-pet">撿到狗貓怎麼辦</a>・<a href="${SITE}g/chip-lost-report">晶片遺失申報</a></p>`;
export async function cityPage(parts) {
  parts = Array.isArray(parts) ? parts : (parts ? [parts] : []);
  if (parts.length > 2) return notFound();
  let city = "", dist = "";
  try { city = normCity(decodeURIComponent(String(parts[0] || ""))); dist = decodeURIComponent(String(parts[1] || "")); } catch (_) { return notFound(); }
  const nav = `<nav class="cities">${CITIES.map((x) => `<a href="${SITE}l/${encodeURIComponent(x)}">${x}</a>`).join("")}</nav>`;
  if (!city) {
    return resp(shell({ title: `各縣市走失的狗貓：尋狗啟事、尋貓啟事總覽｜${NAME}`, desc: "全台各縣市正在協尋的走失狗狗、貓咪，依縣市、鄉鎮市區查看。看到請拍照回報、聯絡飼主；毛孩走失也能免費登記協尋。", canonical: `${SITE}l/`,
      body: `<h1>各縣市走失的狗貓</h1><p class="meta">選你住的縣市，看看附近有沒有正在找家的毛孩。</p>${nav}${GUIDE_LINKS}` }));
  }
  if (!CITIES.includes(city)) return notFound();
  if (dist && !/^[一-鿿]{2,6}$/.test(dist)) return notFound();
  const cUrl = `${SITE}l/${encodeURIComponent(city)}`;
  let all = [];
  try { all = await q(`cases_public?status=eq.searching&lost_city=eq.${encodeURIComponent(city)}&select=id,name,species,lost_city,lost_district,lost_at,photos&order=last_activity.desc&limit=500`) || []; }
  catch (_) { return resp(shell({ title: NAME, desc: "", canonical: cUrl, body: "<p>暫時連不上資料，請稍後再試。</p>", noindex: true }), 503, undefined, 0); }
  const cnt = {}; for (const c of all) if (c.lost_district) cnt[c.lost_district] = (cnt[c.lost_district] || 0) + 1;
  const dnav = Object.keys(cnt).length ? `<nav class="cities">${Object.entries(cnt).sort((a, b) => b[1] - a[1]).map(([d, n]) => `<a href="${cUrl}/${encodeURIComponent(d)}"${d === dist ? ' style="background:var(--red);color:#fff"' : ""}>${esc(d)} ${n}</a>`).join("")}</nav>` : "";
  const list = (dist ? all.filter((c) => c.lost_district === dist) : all).slice(0, 200);
  list.sort((a, b) => ((b.photos || []).length > 0) - ((a.photos || []).length > 0));
  const area = city + dist, url = dist ? `${cUrl}/${encodeURIComponent(dist)}` : cUrl;
  const dogs = list.filter((c) => c.species === "dog").length, cats = list.length - dogs;
  const title = `${area}走失狗、走失貓協尋（${list.length} 隻正在找）｜尋狗啟事・尋貓啟事｜${NAME}`;
  const desc = `${area}目前有 ${dogs} 隻狗、${cats} 隻貓走失，正在找回家的路。看到請不要追，拍照記下時間地點，聯絡飼主。毛孩在${area}走失，也能免費登記協尋、每天比對收容所。`;
  const body = `<h1>${esc(area)}走失的狗狗、貓咪</h1><p class="meta">${esc(`${area}目前有 ${dogs} 隻狗、${cats} 隻貓正在協尋。看到請不要追，拍照記下時間地點，聯絡飼主。`)}</p>
${dist ? `<p><a href="${cUrl}">← ${esc(city)}全部走失毛孩</a></p>` : ""}${dnav ? `<h2>依行政區看</h2>${dnav}` : ""}
${list.length ? `<div class="grid">${list.map(itemHTML).join("")}</div>` : `<p>目前${esc(area)}沒有協尋中的走失毛孩。</p>`}
<a class="btn" href="${SITE}#/new">我的毛孩在${esc(area)}走失了，免費登記協尋</a>
<a class="btn ghost" href="${SITE}#/found/new">我在${esc(area)}撿到／看到走失的毛孩</a>
${GUIDE_LINKS}<h2>其他縣市</h2>${nav}`;
  const jsonld = { "@context": "https://schema.org", "@type": "BreadcrumbList", itemListElement: [
    { "@type": "ListItem", position: 1, name: NAME, item: SITE },
    { "@type": "ListItem", position: 2, name: `${city}走失毛孩`, item: cUrl },
    ...(dist ? [{ "@type": "ListItem", position: 3, name: dist, item: url }] : [])] };
  return resp(shell({ title, desc, canonical: url, body, jsonld, noindex: !!dist && !list.length }));
}

export async function sitemap(waitUntil) {
  let list = [];
  try {
    for (let off = 0; off < 5000; off += 1000) {
      const part = await q(`cases_public?status=eq.searching&select=id,name,last_activity,lost_city,lost_district,photos&order=last_activity.desc&limit=1000&offset=${off}`);
      list = list.concat(part || []);
      if (!part || part.length < 1000) break;
    }
  } catch (_) { return resp("temporarily unavailable", 503, "text/plain", 0); }   // 資料庫暫時連不上：不要回一份缺案件的地圖檔
  let adoptList = [], adoptShel = [], adoptBreeds = [];
  try { const u = await adoptUrls(waitUntil); adoptList = u.animals.slice(0, 20000); adoptShel = u.shelters; adoptBreeds = u.breeds; } catch (_) {}   // 農業部資料讀不到：這次先不放領養頁
  const d = (t) => String(t || "").slice(0, 10);
  const today = new Date().toISOString().slice(0, 10);   // 用 UTC 日期：台灣時間早 8 小時，Google 會當成「未來日期」
  const urls = [`<url><loc>${SITE}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>1.0</priority></url>`,
    `<url><loc>${SITE}app</loc><lastmod>${today}</lastmod><changefreq>monthly</changefreq><priority>0.8</priority></url>`,
    `<url><loc>${SITE}l/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.8</priority></url>`,
    ...CITIES.map((c) => `<url><loc>${SITE}l/${encodeURIComponent(c)}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`),
    ...[...new Set(list.filter((c) => CITIES.includes(c.lost_city) && /^[\u4e00-\u9fff]{2,6}$/.test(c.lost_district || "")).map((c) => `${encodeURIComponent(c.lost_city)}/${encodeURIComponent(c.lost_district)}`))].map((x) => `<url><loc>${SITE}l/${x}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.6</priority></url>`),
    `<url><loc>${SITE}g/</loc><lastmod>${today}</lastmod><changefreq>weekly</changefreq><priority>0.8</priority></url>`,
    ...GUIDE_IDS().map((g) => `<url><loc>${SITE}g/${g}</loc><lastmod>${today}</lastmod><changefreq>monthly</changefreq><priority>0.7</priority></url>`),
    `<url><loc>${SITE}adopt/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`,
    `<url><loc>${SITE}adopt/b/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`,
    `<url><loc>${SITE}adopt/s/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`,
    ...ACITIES.flatMap((c) => ["狗", "貓"].map((k) => `<url><loc>${SITE}adopt/${encodeURIComponent(c)}/${encodeURIComponent(k)}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.6</priority></url>`)),
    ...adoptShel.map((pk) => `<url><loc>${SITE}adopt/s/${pk}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.6</priority></url>`),
    ...adoptBreeds.map((b) => `<url><loc>${SITE}adopt/b/${encodeURIComponent(b)}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.6</priority></url>`),
    ...adoptList.map((a) => `<url><loc>${SITE}adopt/a/${a.id}</loc>${/^\d{4}-\d\d-\d\d$/.test(a.t) && a.t >= "2015-01-01" ? `<lastmod>${a.t > today ? today : a.t}</lastmod>` : ""}<changefreq>weekly</changefreq><priority>0.5</priority></url>`),
    ...list.map((c) => `<url><loc>${SITE}p/${c.id}</loc><lastmod>${d(c.last_activity)}</lastmod><changefreq>daily</changefreq><priority>0.6</priority>${(c.photos || []).slice(0, 3).map(okImg).filter(Boolean).map((u) => `<image:image><image:loc>${esc(u)}</image:loc></image:image>`).join("")}</url>`)];
  return resp(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">\n${urls.join("\n")}\n</urlset>\n`, 200, "application/xml; charset=utf-8", 3600);
}

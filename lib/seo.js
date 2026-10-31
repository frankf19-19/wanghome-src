// 汪喵回家 — 給搜尋引擎看的頁面（Cloudflare Pages Functions，即時產生）
//   /p/<案件>       每一隻走失毛孩一頁：照片、特徵、走失地區、日期（Google 搜得到）
//   /l/<縣市>       這個縣市正在協尋的毛孩
//   /sitemap.xml    所有協尋中的毛孩和縣市頁
// 只讀公開資料（publishable key，本來就公開在網頁裡）。
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
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: { apikey: ANON_KEY, Accept: "application/json" }, cf: { cacheTtl: 300 } });
  if (!r.ok) throw new Error("db " + r.status);
  return r.json();
}
const resp = (body, status = 200, type = "text/html; charset=utf-8", maxAge = 600) => new Response(body, { status, headers: {
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
  const img = okImg(image) || SITE + "og.png";
  return `<!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><meta name="description" content="${esc(desc)}">${noindex ? '<meta name="robots" content="noindex">' : ""}
<link rel="canonical" href="${esc(canonical)}"><link rel="icon" href="${SITE}icon.svg" type="image/svg+xml">
<meta property="og:type" content="article"><meta property="og:site_name" content="${NAME}"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}"><meta property="og:image" content="${esc(img)}"><meta property="og:url" content="${esc(canonical)}"><meta property="og:locale" content="zh_TW"><meta name="twitter:card" content="summary_large_image">
${jsonld ? `<script type="application/ld+json">${JSON.stringify(jsonld).replace(/</g, "\\u003c")}</script>` : ""}
<style>${CSS}</style></head><body>
<header><a href="${SITE}"><img src="${SITE}icon.svg" alt="">${NAME}</a></header><main>${body}</main>
<footer>${NAME}｜全台走失狗貓協尋平台・免費・不收手續費<br><a href="${SITE}">回首頁</a>・<a href="${SITE}l/">各縣市走失毛孩</a></footer></body></html>`;
}

function itemHTML(c) {
  const ph = okImg((c.photos || [])[0]);
  return `<a class="it" href="${SITE}p/${c.id}">${ph ? `<img loading="lazy" src="${esc(thumb(ph))}" alt="${esc(c.name)}">` : '<div class="np"></div>'}<b>${esc(c.name)}</b><small>${esc((c.lost_city || "") + (c.lost_district || ""))}・走失第 ${days(c.lost_at)} 天</small></a>`;
}

export async function casePage(id) {
  id = String(id || "").replace(/\.html$/, "");
  if (!UUID.test(id)) return resp("Not found", 404, "text/plain", 60);
  let c;
  try { c = (await q(`cases_public?id=eq.${id}&select=id,species,name,status,breed,sex,size,colour,features,collar_desc,temperament,has_chip,lost_city,lost_district,lost_place,lost_at,photos,reward,contact_phone,source&limit=1`))[0]; }
  catch (_) { return resp(shell({ title: NAME, desc: "", canonical: `${SITE}p/${id}`, body: `<p>暫時連不上資料，請<a href="${SITE}#/case/${id}">打開協尋頁</a>。</p>`, noindex: true }), 503, undefined, 0); }
  if (!c) return resp(shell({ title: `${NAME}｜找不到這個頁面`, desc: "這個協尋可能已經結束。", canonical: `${SITE}p/${id}`, body: `<h1>這個協尋已經不在了</h1><p>可能已經找到或結案了。<a href="${SITE}">回首頁看其他正在找的毛孩</a></p>`, noindex: true }), 404, undefined, 300);
  const [unit, poster] = SP[c.species] || SP.dog;
  const area = `${c.lost_city || ""}${c.lost_district || ""}`;
  const searching = c.status === "searching";
  const look = [c.breed, SEX[c.sex], c.size ? SIZE[c.size] : "", c.colour].filter(Boolean).join("・");
  const title = searching ? `【${poster}】${c.name}｜${area}・${twDate(c.lost_at)} 走失｜${NAME}` : c.status === "found" ? `${c.name} 已經找到了｜${NAME}` : `${c.name}（協尋已結束）｜${NAME}`;
  const desc = [`${area}走失的${look || unit}「${c.name}」`, c.features || "", searching ? "看到請不要追，拍照記下時間地點，聯絡飼主。" : ""].filter(Boolean).join("。").slice(0, 160);
  const ph = okImg((c.photos || [])[0]);
  const tel = searching && c.contact_phone ? String(c.contact_phone).replace(/[^\d+#]/g, "") : "";
  let others = [];
  try { others = (await q(`cases_public?status=eq.searching&lost_city=eq.${encodeURIComponent(c.lost_city)}&id=neq.${id}&photos=not.eq.%7B%7D&select=id,name,lost_city,lost_district,lost_at,photos&order=last_activity.desc&limit=8`)) || []; } catch (_) {}
  const body = `${searching ? `<span class="badge">走失第 ${days(c.lost_at)} 天</span>` : ""}
<h1>${esc(searching ? `${poster}｜${c.name}` : title.replace(`｜${NAME}`, ""))}</h1>
<p class="meta">📍 ${esc(area)}${c.lost_place ? "　" + esc(c.lost_place) : ""}　走失於 ${esc(twDate(c.lost_at))}${c.source === "moa" ? "　（農業部寵物登記網遺失申報）" : ""}</p>
<div class="hero">${ph ? `<img class="ph" src="${esc(ph)}" alt="${esc(c.name)}的照片">` : ""}
<div class="card"><dl>${look ? `<dt>特徵</dt><dd>${esc(look)}</dd>` : ""}${c.features ? `<dt>辨識</dt><dd>${esc(c.features)}</dd>` : ""}${c.collar_desc ? `<dt>項圈</dt><dd>${esc(c.collar_desc)}</dd>` : ""}${c.temperament ? `<dt>個性</dt><dd>${esc(c.temperament)}</dd>` : ""}<dt>晶片</dt><dd>${c.has_chip ? "有" : "無／不確定"}</dd>${c.reward ? `<dt>獎金</dt><dd>NT$${Number(c.reward).toLocaleString("en-US")}</dd>` : ""}</dl>
${searching ? `<p class="tip">看到${esc(c.name)}：<b>不要叫、不要追</b>，拍照記下時間地點，聯絡飼主。</p>` : ""}
${tel ? `<a class="btn" href="tel:${esc(tel)}">📞 看到牠了，打給飼主</a>` : ""}
<a class="btn ${tel ? "ghost" : ""}" href="${SITE}#/case/${id}">打開完整協尋頁（地圖、海報、分享）</a></div></div>
${others.length ? `<h2>${esc(c.lost_city)}其他正在找的毛孩</h2><div class="grid">${others.map(itemHTML).join("")}</div><p><a href="${SITE}l/${encodeURIComponent(c.lost_city)}">看${esc(c.lost_city)}全部走失毛孩 →</a></p>` : ""}`;
  const jsonld = { "@context": "https://schema.org", "@type": "WebPage", name: title, description: desc, ...(ph ? { image: ph } : {}), datePublished: c.lost_at };
  return resp(shell({ title, desc, canonical: `${SITE}p/${id}`, image: ph, body, noindex: !searching, jsonld }));
}

export async function cityPage(city) {
  city = normCity(decodeURIComponent(String(city || "")));
  const nav = `<nav class="cities">${CITIES.map((x) => `<a href="${SITE}l/${encodeURIComponent(x)}">${x}</a>`).join("")}</nav>`;
  if (!city) {
    return resp(shell({ title: `各縣市走失的狗貓｜${NAME}`, desc: "全台各縣市正在協尋的走失狗狗、貓咪，看到請拍照回報、聯絡飼主。", canonical: `${SITE}l/`,
      body: `<h1>各縣市走失的狗貓</h1><p class="meta">選你住的縣市，看看附近有沒有正在找家的毛孩。</p>${nav}` }));
  }
  if (!CITIES.includes(city)) return resp("Not found", 404, "text/plain", 300);
  let list = [];
  try { list = await q(`cases_public?status=eq.searching&lost_city=eq.${encodeURIComponent(city)}&select=id,name,species,lost_city,lost_district,lost_at,photos&order=last_activity.desc&limit=200`) || []; }
  catch (_) { return resp(shell({ title: NAME, desc: "", canonical: `${SITE}l/${encodeURIComponent(city)}`, body: "<p>暫時連不上資料，請稍後再試。</p>", noindex: true }), 503, undefined, 0); }
  list.sort((a, b) => ((b.photos || []).length > 0) - ((a.photos || []).length > 0));
  const dogs = list.filter((c) => c.species === "dog").length, cats = list.length - dogs;
  const title = `${city}走失的狗狗、貓咪（${list.length} 隻正在找）｜${NAME}`;
  const desc = `${city}目前有 ${dogs} 隻狗、${cats} 隻貓走失，正在找回家的路。看到請不要追，拍照記下時間地點，聯絡飼主。`;
  const body = `<h1>${esc(city)}走失的毛孩</h1><p class="meta">${esc(desc)}</p>
${list.length ? `<div class="grid">${list.map(itemHTML).join("")}</div>` : `<p>目前${esc(city)}沒有協尋中的走失毛孩。</p>`}
<a class="btn" href="${SITE}#/new">我的毛孩走失了，免費登記協尋</a>
<h2>其他縣市</h2>${nav}`;
  return resp(shell({ title, desc, canonical: `${SITE}l/${encodeURIComponent(city)}`, body }));
}

export async function sitemap() {
  let list = [];
  try {
    for (let off = 0; off < 5000; off += 1000) {
      const part = await q(`cases_public?status=eq.searching&select=id,last_activity&order=last_activity.desc&limit=1000&offset=${off}`);
      list = list.concat(part || []);
      if (!part || part.length < 1000) break;
    }
  } catch (_) {}
  const d = (t) => String(t || "").slice(0, 10);
  const today = new Date(Date.now() + 8 * 3600e3).toISOString().slice(0, 10);
  const urls = [`<url><loc>${SITE}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>1.0</priority></url>`,
    `<url><loc>${SITE}l/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.8</priority></url>`,
    ...CITIES.map((c) => `<url><loc>${SITE}l/${encodeURIComponent(c)}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`),
    ...list.map((c) => `<url><loc>${SITE}p/${c.id}</loc><lastmod>${d(c.last_activity)}</lastmod><changefreq>daily</changefreq><priority>0.6</priority></url>`)];
  return resp(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join("\n")}\n</urlset>\n`, 200, "application/xml; charset=utf-8", 3600);
}

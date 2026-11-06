// 汪喵回家 — 領養的靜態頁（給搜尋引擎看，Cloudflare Pages Functions 即時產生）
//   /adopt/                    各縣市待領養的狗貓
//   /adopt/<縣市>/<狗|貓>       這個縣市收容所待領養的狗或貓（例：/adopt/臺中市/狗）
//   /adopt/a/<animal_id>        一隻待領養毛孩：照片、特徵、收容所、電話（搜「收容編號」「領養 柴犬 台中」找得到）
// 資料：農業部「動物認領養」開放資料（只留開放認養的），快取 1 小時，和 /api/moa/adopt 共用。
const SITE = "https://wangmiaotw.com/";
const NAME = "汪喵回家";
export const CITIES = ["臺北市","新北市","桃園市","臺中市","臺南市","高雄市","基隆市","新竹市","新竹縣","苗栗縣","彰化縣","南投縣","雲林縣","嘉義市","嘉義縣","屏東縣","宜蘭縣","花蓮縣","臺東縣","澎湖縣","金門縣","連江縣"];
const AREA = {"臺北市":2,"新北市":3,"基隆市":4,"宜蘭縣":5,"桃園市":6,"新竹縣":7,"新竹市":8,"苗栗縣":9,"臺中市":10,"彰化縣":11,"南投縣":12,"雲林縣":13,"嘉義縣":14,"嘉義市":15,"臺南市":16,"高雄市":17,"屏東縣":18,"花蓮縣":19,"臺東縣":20,"澎湖縣":21,"金門縣":22,"連江縣":23};
const CITY_OF = Object.fromEntries(Object.entries(AREA).map(([c, n]) => [String(n), c]));
const KEEP = ["animal_id", "animal_subid", "animal_area_pkid", "animal_shelter_pkid", "animal_kind", "animal_Variety", "animal_sex", "animal_bodytype",
  "animal_colour", "animal_age", "animal_sterilization", "animal_bacterin", "animal_foundplace", "animal_remark", "album_file", "animal_createtime",
  "animal_opendate", "shelter_name", "animal_place", "shelter_tel", "shelter_address", "animal_status"];
const SEX = { M: "公", F: "母" }, SIZE = { SMALL: "小型", MEDIUM: "中型", BIG: "大型" }, AGE = { CHILD: "幼年", ADULT: "成年" };

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const pic = (u) => { u = String(u || "").trim(); if (/^http:\/\//i.test(u)) u = "https://" + u.slice(7); return /^https:\/\/[^\s'"()<>\\]+$/.test(u) ? u : ""; };
const normCity = (c) => String(c || "").replace(/^台/, "臺");
const sp = (k) => (k === "貓" ? "貓" : "狗");
const spWord = (k) => (k === "貓" ? "貓咪" : "狗狗");

// 農業部資料（狗或貓全台），快取 1 小時；/api/moa/adopt 也用這份
export async function moaAdopt(kind, waitUntil) {
  const key = new Request(`https://wangmiaotw.com/api/moa/adopt/v1/${encodeURIComponent(kind)}`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) { try { return await hit.json(); } catch (_) {} }
  const r = await fetch(`https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=QcbUEzN6E6DL&animal_kind=${encodeURIComponent(kind)}`,
    { headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com)" } });
  const j = await r.json();
  if (!r.ok || !Array.isArray(j)) throw new Error("upstream");
  const slim = j.filter((a) => a && a.animal_status === "OPEN").map((a) => { const o = {}; for (const k of KEEP) if (a[k] !== undefined && a[k] !== "") o[k] = a[k]; return o; });
  const body = JSON.stringify(slim);
  const p = cache.put(key, new Response(body, { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=3600" } }));
  if (waitUntil) waitUntil(p); else await p;
  return slim;
}

const resp = (body, status = 200, maxAge = 1800) => new Response(body, { status, headers: {
  "content-type": "text/html; charset=utf-8", "cache-control": `public, max-age=${maxAge}`, "x-content-type-options": "nosniff" } });

const CSS = `:root{--ink:#2B2326;--mute:#6F6468;--red:#B8335A;--bg:#FDF6F8;--card:#fff;--line:#EADDE2}
*{box-sizing:border-box}body{margin:0;font-family:system-ui,"PingFang TC","Noto Sans TC","Microsoft JhengHei",sans-serif;background:var(--bg);color:var(--ink);line-height:1.6}
a{color:var(--red)}header{display:flex;align-items:center;gap:10px;padding:14px 16px;max-width:960px;margin:0 auto}header a{display:flex;align-items:center;gap:8px;text-decoration:none;color:var(--ink);font-weight:800;font-size:18px}header img{width:28px;height:28px}
main{max-width:960px;margin:0 auto;padding:0 16px 40px}h1{font-size:26px;line-height:1.3;margin:8px 0 6px}.meta{color:var(--mute);margin:0 0 14px}
.hero{display:grid;gap:18px}@media(min-width:760px){.hero{grid-template-columns:1fr 1fr}}.ph{width:100%;aspect-ratio:1;object-fit:cover;border-radius:20px;background:#eee}
.card{background:var(--card);border-radius:20px;padding:16px 18px;box-shadow:0 10px 24px -18px rgba(90,30,50,.35)}dl{display:grid;grid-template-columns:auto 1fr;gap:6px 14px;margin:0}dt{color:var(--mute);font-weight:700}dd{margin:0}
.btn{display:block;text-align:center;background:var(--red);color:#fff;text-decoration:none;font-weight:800;padding:14px;border-radius:16px;margin-top:12px}.btn.ghost{background:#fff;color:var(--ink);border:1.5px solid var(--line)}
.tip{background:#FFF6DC;border-radius:14px;padding:10px 14px;margin-top:12px;font-size:15px}.badge{display:inline-block;background:var(--red);color:#fff;border-radius:99px;padding:2px 10px;font-size:13px;font-weight:800}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;margin-top:12px}.it{display:block;text-decoration:none;color:var(--ink);background:var(--card);border-radius:16px;overflow:hidden}.it img,.it .np{width:100%;aspect-ratio:1;object-fit:cover;display:block;background:#F1E6EA}.it b{display:block;padding:8px 10px 0;font-size:15px}.it small{display:block;padding:0 10px 10px;color:var(--mute);font-size:13px}
h2{font-size:20px;margin:28px 0 4px}nav.cities{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}nav.cities a{background:#fff;border-radius:99px;padding:6px 12px;text-decoration:none;color:var(--ink);font-size:14px}
table{border-collapse:collapse;width:100%;background:#fff;border-radius:16px;overflow:hidden}td,th{padding:8px 12px;border-bottom:1px solid var(--line);text-align:left;font-size:15px}th{color:var(--mute)}
footer{max-width:960px;margin:0 auto;padding:16px;color:var(--mute);font-size:13px;border-top:1px solid var(--line)}`;

function shell({ title, desc, canonical, image, body, noindex = false, jsonld = null }) {
  const img = pic(image) || SITE + "og.png";
  return `<!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="apple-itunes-app" content="app-id=6827632980">
<title>${esc(title)}</title><meta name="description" content="${esc(desc)}">${noindex ? '<meta name="robots" content="noindex">' : ""}
<link rel="canonical" href="${esc(canonical)}"><link rel="icon" href="${SITE}icon.svg" type="image/svg+xml">
<meta property="og:type" content="article"><meta property="og:site_name" content="${NAME}"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}"><meta property="og:image" content="${esc(img)}"><meta property="og:url" content="${esc(canonical)}"><meta property="og:locale" content="zh_TW"><meta name="twitter:card" content="summary_large_image">
${jsonld ? `<script type="application/ld+json">${JSON.stringify(jsonld).replace(/</g, "\\u003c")}</script>` : ""}
<style>${CSS}</style></head><body>
<header><a href="${SITE}"><img src="${SITE}icon.svg" alt="">${NAME}</a></header><main>${body}</main>
<footer>${NAME}｜全台走失狗貓協尋平台・免費・不收手續費<br>領養資料來自農業部「動物認領養」開放資料，實際狀況以收容所為準。<br><a href="${SITE}">回首頁</a>・<a href="${SITE}adopt/">各縣市待領養毛孩</a>・<a href="${SITE}l/">各縣市走失毛孩</a>・<a href="${SITE}g/adopt-prep">新手領養準備清單</a></footer></body></html>`;
}

function look(a) { return [String(a.animal_Variety || "").trim(), SEX[a.animal_sex], SIZE[a.animal_bodytype], String(a.animal_colour || "").trim()].filter(Boolean).join("・"); }
function label(a) { const v = String(a.animal_Variety || "").trim(); return `${v && v !== "混種" ? v : "米克斯"}${String(a.animal_colour || "").trim()}${spWord(a.animal_kind)}`; }
const cityOf = (a) => CITY_OF[String(a.animal_area_pkid)] || "";
const itemHTML = (a) => { const ph = pic(a.album_file);
  return `<a class="it" href="${SITE}adopt/a/${encodeURIComponent(a.animal_id)}">${ph ? `<img loading="lazy" src="${esc(ph)}" alt="${esc(label(a))}">` : '<div class="np"></div>'}<b>${esc(label(a))}</b><small>${esc([SEX[a.animal_sex], a.shelter_name || a.animal_place].filter(Boolean).join("・"))}</small></a>`; };
const cityNav = (kind) => `<nav class="cities">${CITIES.map((c) => `<a href="${SITE}adopt/${encodeURIComponent(c)}/${encodeURIComponent(kind)}">${c}</a>`).join("")}</nav>`;
const notFound = () => resp(shell({ title: `${NAME}｜找不到這個頁面`, desc: "", canonical: `${SITE}adopt/`, body: `<h1>找不到這個頁面</h1><p>這隻毛孩可能已經被領養了。</p><a class="btn" href="${SITE}adopt/">看其他待領養的毛孩</a>`, noindex: true }), 404, 600);
const down = (canonical) => resp(shell({ title: NAME, desc: "", canonical, body: `<h1>暫時讀不到收容所資料</h1><p>請稍後再試，或<a href="${SITE}#/adopt">打開汪喵回家的領養頁</a>。</p>`, noindex: true }), 503, 0);

export async function adoptRoute(parts, waitUntil) {
  parts = (parts || []).map((p) => { try { return decodeURIComponent(p); } catch (_) { return "\u0000"; } });
  if (parts.length === 0 || (parts.length === 1 && parts[0] === "")) return adoptIndex(waitUntil);
  if (parts[0] === "a" && parts.length === 2) return adoptOne(parts[1], waitUntil);
  if (parts.length === 2) return adoptCity(normCity(parts[0]), parts[1], waitUntil);
  return notFound();
}

async function adoptIndex(waitUntil) {
  let dogs = [], cats = [];
  try { [dogs, cats] = await Promise.all([moaAdopt("狗", waitUntil), moaAdopt("貓", waitUntil)]); } catch (_) { return down(`${SITE}adopt/`); }
  const count = (list) => { const m = {}; for (const a of list) { const c = cityOf(a); if (c) m[c] = (m[c] || 0) + 1; } return m; };
  const dc = count(dogs), cc = count(cats);
  const title = `全台收容所待領養的狗狗、貓咪（${dogs.length + cats.length} 隻）｜${NAME}`;
  const desc = `全台公立收容所目前有 ${dogs.length} 隻狗、${cats.length} 隻貓等待領養。依縣市看照片、品種、收容所電話，領養代替購買。`;
  const rows = CITIES.map((c) => `<tr><td>${c}</td><td><a href="${SITE}adopt/${encodeURIComponent(c)}/${encodeURIComponent("狗")}">狗狗 ${dc[c] || 0} 隻</a></td><td><a href="${SITE}adopt/${encodeURIComponent(c)}/${encodeURIComponent("貓")}">貓咪 ${cc[c] || 0} 隻</a></td></tr>`).join("");
  const body = `<h1>全台待領養的狗狗、貓咪</h1><p class="meta">${esc(desc)}</p>
<table><thead><tr><th>縣市</th><th>狗狗</th><th>貓咪</th></tr></thead><tbody>${rows}</tbody></table>
<a class="btn" href="${SITE}#/adopt">用汪喵回家找領養（可篩選品種、年齡）</a>
<a class="btn ghost" href="${SITE}g/adopt-prep">領養前要準備什麼？新手清單</a>`;
  return resp(shell({ title, desc, canonical: `${SITE}adopt/`, body }));
}

async function adoptCity(city, kind, waitUntil) {
  if (!AREA[city] || !["狗", "貓"].includes(kind)) return notFound();
  const canonical = `${SITE}adopt/${encodeURIComponent(city)}/${encodeURIComponent(kind)}`;
  let all = [];
  try { all = await moaAdopt(kind, waitUntil); } catch (_) { return down(canonical); }
  const list = all.filter((a) => cityOf(a) === city).sort((a, b) => (pic(b.album_file) ? 1 : 0) - (pic(a.album_file) ? 1 : 0));
  const shelters = [...new Set(list.map((a) => a.shelter_name || a.animal_place).filter(Boolean))];
  const title = `${city}領養${spWord(kind)}｜收容所 ${list.length} 隻待領養｜${NAME}`;
  const desc = `${city}${shelters.length ? "（" + shelters.slice(0, 3).join("、") + "）" : ""}目前有 ${list.length} 隻${sp(kind)}等待領養，看照片、品種、性別與收容所電話。`.slice(0, 160);
  const other = kind === "狗" ? "貓" : "狗";
  const body = `<h1>${esc(city)}待領養的${spWord(kind)}</h1><p class="meta">${esc(desc)}</p>
${list.length ? `<div class="grid">${list.slice(0, 300).map(itemHTML).join("")}</div>` : `<p>目前${esc(city)}收容所沒有開放領養的${sp(kind)}。</p>`}
<p class="tip">想領養之前，先打電話給收容所確認牠還在，說出收容編號；帶身分證去，現場會有簡單的評估。</p>
<a class="btn ghost" href="${SITE}adopt/${encodeURIComponent(city)}/${encodeURIComponent(other)}">看${esc(city)}待領養的${spWord(other)}</a>
<h2>其他縣市的${spWord(kind)}</h2>${cityNav(kind)}`;
  const jsonld = { "@context": "https://schema.org", "@type": "CollectionPage", name: `${city}待領養的${spWord(kind)}`, url: canonical, isPartOf: { "@type": "WebSite", name: NAME, url: SITE } };
  return resp(shell({ title, desc, canonical, image: list[0] && list[0].album_file, body, jsonld }));
}

async function adoptOne(id, waitUntil) {
  if (!/^\d{1,12}$/.test(id)) return notFound();
  let a = null;
  try { const [d, c] = await Promise.all([moaAdopt("狗", waitUntil), moaAdopt("貓", waitUntil)]); a = d.concat(c).find((x) => String(x.animal_id) === id) || null; }
  catch (_) { return down(`${SITE}adopt/a/${id}`); }
  if (!a) return notFound();
  const city = cityOf(a), shelter = a.shelter_name || a.animal_place || "", ph = pic(a.album_file);
  const title = `【待領養】${label(a)}${a.animal_sex && SEX[a.animal_sex] ? "（" + SEX[a.animal_sex] + "）" : ""}｜${city}${shelter && shelter !== city ? "・" + shelter : ""}｜${NAME}`;
  const desc = [`${city}${shelter}待領養的${look(a) || spWord(a.animal_kind)}`, a.animal_subid ? `收容編號 ${a.animal_subid}` : "", String(a.animal_remark || "").trim().slice(0, 60), "領養前請先打電話給收容所確認。"].filter(Boolean).join("。").slice(0, 160);
  const tel = String(a.shelter_tel || "").replace(/[^\d#+-]/g, "");
  const rows = [["品種", a.animal_Variety], ["性別", SEX[a.animal_sex]], ["體型", SIZE[a.animal_bodytype]], ["毛色", a.animal_colour], ["年紀", AGE[a.animal_age]],
    ["結紮", a.animal_sterilization === "T" ? "已結紮" : a.animal_sterilization === "F" ? "未結紮" : ""], ["收容編號", a.animal_subid], ["發現地點", a.animal_foundplace],
    ["收容所", shelter], ["地址", a.shelter_address], ["開放領養", String(a.animal_opendate || "").replace(/-/g, "/")]].filter(([, v]) => v && String(v).trim());
  const body = `<span class="badge">待領養</span><h1>${esc(label(a))}</h1>
<p class="meta">📍 ${esc(city)}　${esc(shelter)}</p>
<div class="hero">${ph ? `<img class="ph" src="${esc(ph)}" alt="${esc(label(a))}的照片">` : ""}
<div><div class="card"><dl>${rows.map(([k, v]) => `<dt>${k}</dt><dd>${esc(String(v).trim())}</dd>`).join("")}</dl>
${a.animal_remark ? `<p style="margin:12px 0 0">${esc(String(a.animal_remark).trim())}</p>` : ""}</div>
${tel ? `<a class="btn" href="tel:${esc(tel)}">打電話給收容所（${esc(a.shelter_tel)}）</a>` : ""}
<a class="btn ghost" href="${SITE}#/adopt/${encodeURIComponent(id)}">在汪喵回家收藏、分享這隻</a>
<p class="tip">先打電話確認牠還在，說出收容編號${a.animal_subid ? " " + esc(a.animal_subid) : ""}；帶身分證去，現場會有簡單的評估。</p></div></div>
<h2>${esc(city)}還有更多${spWord(a.animal_kind)}在等家</h2><a class="btn ghost" href="${SITE}adopt/${encodeURIComponent(city)}/${encodeURIComponent(sp(a.animal_kind))}">看${esc(city)}所有待領養的${spWord(a.animal_kind)}</a>`;
  const jsonld = { "@context": "https://schema.org", "@type": "WebPage", name: title, description: desc, url: `${SITE}adopt/a/${id}`, image: ph || undefined,
    breadcrumb: { "@type": "BreadcrumbList", itemListElement: [
      { "@type": "ListItem", position: 1, name: NAME, item: SITE },
      { "@type": "ListItem", position: 2, name: "待領養毛孩", item: `${SITE}adopt/` },
      { "@type": "ListItem", position: 3, name: `${city}${spWord(a.animal_kind)}`, item: `${SITE}adopt/${encodeURIComponent(city)}/${encodeURIComponent(sp(a.animal_kind))}` },
      { "@type": "ListItem", position: 4, name: label(a), item: `${SITE}adopt/a/${id}` }] } };
  return resp(shell({ title, desc, canonical: `${SITE}adopt/a/${id}`, image: ph, body, jsonld }));
}

// sitemap 用：所有待領養毛孩與縣市頁的網址
export async function adoptUrls(waitUntil) {
  const [d, c] = await Promise.all([moaAdopt("狗", waitUntil), moaAdopt("貓", waitUntil)]);
  return { animals: d.concat(c).map((a) => ({ id: String(a.animal_id), t: String(a.animal_opendate || a.animal_createtime || "").replace(/\//g, "-").slice(0, 10) })) };
}

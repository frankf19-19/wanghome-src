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
  // 備用的一份（保存 7 天）：農業部主機暫時連不上時先用舊資料，頁面不會變成 503（搜尋引擎會把 5xx 的頁面移出索引）
  const stale = new Request(`https://wangmiaotw.com/api/moa/adopt/stale1/${encodeURIComponent(kind)}`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) { try { return await hit.json(); } catch (_) {} }
  let slim = null;
  try {
    const r = await fetch(`https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=QcbUEzN6E6DL&animal_kind=${encodeURIComponent(kind)}`,
      { headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com)" } });
    const j = await r.json();
    if (!r.ok || !Array.isArray(j) || !j.length) throw new Error("upstream");
    slim = j.filter((a) => a && a.animal_status === "OPEN").map((a) => { const o = {}; for (const k of KEEP) if (a[k] !== undefined && a[k] !== "") o[k] = a[k]; return o; });
  } catch (e) {
    const old = await cache.match(stale);
    if (old) { try { return await old.json(); } catch (_) {} }
    throw e;
  }
  const body = JSON.stringify(slim);
  const put = (k, age) => cache.put(k, new Response(body, { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": `public, max-age=${age}` } }));
  const p = Promise.all([put(key, 3600), put(stale, 604800)]);
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
  const img = pic(image) || SITE + "og.png?v=2";
  return `<!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="apple-itunes-app" content="app-id=6827632980">
<title>${esc(title)}</title><meta name="description" content="${esc(desc)}">${noindex ? '<meta name="robots" content="noindex">' : ""}
<link rel="canonical" href="${esc(canonical)}"><link rel="icon" href="${SITE}icon.svg" type="image/svg+xml">
<meta property="og:type" content="article"><meta property="og:site_name" content="${NAME}"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}"><meta property="og:image" content="${esc(img)}"><meta property="og:url" content="${esc(canonical)}"><meta property="og:locale" content="zh_TW"><meta name="twitter:card" content="summary_large_image">
${jsonld ? `<script type="application/ld+json">${JSON.stringify(jsonld).replace(/</g, "\\u003c")}</script>` : ""}
<style>${CSS}</style></head><body>
<header><a href="${SITE}"><img src="${SITE}icon.svg" alt="">${NAME}</a></header><main>${body}</main>
<footer>${NAME}｜全台走失狗貓協尋平台・免費・不收手續費<br>領養資料來自農業部「動物認領養」開放資料，實際狀況以收容所為準。<br><a href="${SITE}">回首頁</a>・<a href="${SITE}adopt/">各縣市待領養毛孩</a>・<a href="${SITE}l/">各縣市走失毛孩</a>・<a href="${SITE}g/adopt-prep">新手領養準備清單</a>・<a href="${SITE}app">下載 App</a></footer></body></html>`;
}

function look(a) { return [String(a.animal_Variety || "").trim(), SEX[a.animal_sex], SIZE[a.animal_bodytype], String(a.animal_colour || "").trim()].filter(Boolean).join("・"); }
function label(a) { const v = String(a.animal_Variety || "").trim(), col = String(a.animal_colour || "").trim();
  return v && !/^(混種|米克斯|其他|不詳|未知)/.test(v) ? `${col}${v}` : `${col}米克斯${spWord(a.animal_kind)}`; }
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
  if (parts[0] === "s" && (parts.length === 1 || (parts.length === 2 && parts[1] === ""))) return adoptShelterIndex(waitUntil);
  if (parts[0] === "s" && parts.length === 2) return adoptShelter(parts[1], waitUntil);
  if (parts[0] === "b" && (parts.length === 1 || (parts.length === 2 && parts[1] === ""))) return adoptBreedIndex(waitUntil);
  if (parts[0] === "b" && parts.length === 2) return adoptBreed(parts[1], waitUntil);
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
<h2>各收容所</h2><nav class="cities">${shelterList(dogs.concat(cats)).map((x) => `<a href="${shelterLink(x)}">${esc(x.name)}（${x.dog + x.cat}）</a>`).join("")}</nav>
<h2>依品種找</h2><nav class="cities">${breeds(dogs.concat(cats)).slice(0, 30).map((x) => `<a href="${breedLink(x.breed)}">${esc(x.breed)}（${x.n}）</a>`).join("")}</nav>
<a class="btn ghost" href="${SITE}adopt/b/">看全部品種（貴賓、柴犬、約克夏、米克斯以外的品種貓狗）</a>
<a class="btn ghost" href="${SITE}adopt/s/">全台動物收容所一覽（電話、地址）</a>
<a class="btn" href="${SITE}#/adopt">用汪喵回家找領養（可篩選品種、年齡）</a>
<a class="btn ghost" href="${SITE}g/adopt-prep">領養前要準備什麼？新手清單</a>`;
  return resp(shell({ title, desc, canonical: `${SITE}adopt/`, body }));
}

// 讓看領養的人留下來：收藏、下載 App
const JOIN = `<div class="card" style="margin-top:16px"><b>喜歡的毛孩先收藏起來</b><p class="meta" style="margin:4px 0 0;font-size:14px">免費加入汪喵回家，收藏想領養的毛孩、分享給家人一起看；也有毛孩健康手冊和走失協尋。</p><a class="btn" href="${SITE}#/adopt">打開汪喵回家領養頁</a><a class="btn ghost" href="${SITE}app">下載 App（免費）</a></div>`;
// 領養常見問題（各縣市規定略有不同，內容寫通則並提醒先打電話確認）
const FAQ = (city, kind) => [
  [`在${city}收容所領養${sp(kind)}要錢嗎？`, `公立收容所領養本身通常不收費。依各縣市規定，可能需要負擔晶片、寵物登記或狂犬病疫苗等費用，也有縣市提供免費或補助。出發前打電話給收容所問清楚最準。`],
  [`領養${sp(kind)}需要什麼條件、要帶什麼？`, `一般需要成年、帶身分證件，現場會有簡單的訪談或評估，確認居住環境和照顧能力。部分收容所需要先預約，建議先打電話確認開放時間。`],
  [`網站上看到的${sp(kind)}還在嗎？`, `這裡的資料來自農業部全國動物收容管理系統，每天更新，但毛孩隨時可能被領養。看到喜歡的，請先打電話給收容所，報上收容編號確認。`],
  [`我的${sp(kind)}走失了，會在收容所嗎？`, `有可能。被民眾或動保員送進收容所的毛孩會出現在這裡。到汪喵回家免費登記走失，系統每天會自動比對全台收容所新收的毛孩。`]];
const faqHTML = (city, kind) => `<h2>${esc(city)}領養${spWord(kind)}常見問題</h2>${FAQ(city, kind).map(([q, a]) => `<details class="card" style="margin-top:8px;padding:12px 16px"><summary style="font-weight:800;cursor:pointer">${esc(q)}</summary><p style="margin:8px 0 0">${esc(a)}</p></details>`).join("")}`;
async function adoptCity(city, kind, waitUntil) {
  if (!AREA[city] || !["狗", "貓"].includes(kind)) return notFound();
  const canonical = `${SITE}adopt/${encodeURIComponent(city)}/${encodeURIComponent(kind)}`;
  let all = [];
  try { all = await moaAdopt(kind, waitUntil); } catch (_) { return down(canonical); }
  const list = all.filter((a) => cityOf(a) === city).sort((a, b) => (pic(b.album_file) ? 1 : 0) - (pic(a.album_file) ? 1 : 0));
  const shelters = [...new Set(list.map((a) => a.shelter_name || a.animal_place).filter(Boolean))];
  const title = `${city}${spWord(kind)}領養｜${city}收容所、動物之家 ${list.length} 隻待領養・每日更新｜${NAME}`;
  const desc = `${city}${shelters.length ? "（" + shelters.slice(0, 3).join("、") + "）" : ""}目前有 ${list.length} 隻${sp(kind)}等待領養，資料每天更新。看照片、品種、性別、收容所電話與地址，領養不用買。`.slice(0, 160);
  const other = kind === "狗" ? "貓" : "狗";
  const body = `<h1>${esc(city)}待領養的${spWord(kind)}</h1><p class="meta">${esc(desc)}</p>
${list.length ? `<div class="grid">${list.slice(0, 300).map(itemHTML).join("")}</div>` : `<p>目前${esc(city)}收容所沒有開放領養的${sp(kind)}。</p>`}
<p class="tip">想領養之前，先打電話給收容所確認牠還在，說出收容編號；帶身分證去，現場會有簡單的評估。</p>
${JOIN}
<a class="btn ghost" href="${SITE}adopt/${encodeURIComponent(city)}/${encodeURIComponent(other)}">看${esc(city)}待領養的${spWord(other)}</a>
${faqHTML(city, kind)}
${(() => { let ss = []; try { ss = shelterList(all).filter((x) => x.city === city); } catch (_) {} return ss.length ? `<h2>${esc(city)}的收容所</h2><nav class="cities">${ss.map((x) => `<a href="${shelterLink(x)}">${esc(x.name)}</a>`).join("")}</nav>` : ""; })()}
<h2>其他縣市的${spWord(kind)}</h2>${cityNav(kind)}`;
  const jsonld = { "@context": "https://schema.org", "@graph": [
    { "@type": "CollectionPage", name: `${city}待領養的${spWord(kind)}`, url: canonical, isPartOf: { "@type": "WebSite", name: NAME, url: SITE } },
    { "@type": "FAQPage", mainEntity: FAQ(city, kind).map(([q, a]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a } })) }] };
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
<a class="btn ghost" href="${SITE}#/adopt/${encodeURIComponent(id)}">在汪喵回家收藏、分享這隻（免費）</a>
<p class="tip">先打電話確認牠還在，說出收容編號${a.animal_subid ? " " + esc(a.animal_subid) : ""}；帶身分證去，現場會有簡單的評估。</p></div></div>
${share(`${SITE}adopt/a/${id}`, "分享給可能想領養的朋友，牠就多一次被看見的機會。")}
${/^\d+$/.test(String(a.animal_shelter_pkid || "")) ? `<a class="btn ghost" href="${SITE}adopt/s/${a.animal_shelter_pkid}">${esc(shelter)}還有哪些毛孩在等家</a>` : ""}
<h2>${esc(city)}還有更多${spWord(a.animal_kind)}在等家</h2><a class="btn ghost" href="${SITE}adopt/${encodeURIComponent(city)}/${encodeURIComponent(sp(a.animal_kind))}">看${esc(city)}所有待領養的${spWord(a.animal_kind)}</a>`;
  const jsonld = { "@context": "https://schema.org", "@type": "WebPage", name: title, description: desc, url: `${SITE}adopt/a/${id}`, image: ph || undefined,
    breadcrumb: { "@type": "BreadcrumbList", itemListElement: [
      { "@type": "ListItem", position: 1, name: NAME, item: SITE },
      { "@type": "ListItem", position: 2, name: "待領養毛孩", item: `${SITE}adopt/` },
      { "@type": "ListItem", position: 3, name: `${city}${spWord(a.animal_kind)}`, item: `${SITE}adopt/${encodeURIComponent(city)}/${encodeURIComponent(sp(a.animal_kind))}` },
      { "@type": "ListItem", position: 4, name: label(a), item: `${SITE}adopt/a/${id}` }] } };
  return resp(shell({ title, desc, canonical: `${SITE}adopt/a/${id}`, image: ph, body, jsonld }));
}

// ---- 收容所、品種 ----
const MIX = /^(混種|米克斯|其他|不詳|未知)/;
const breedOf = (a) => { const v = String(a.animal_Variety || "").trim(); return v && !MIX.test(v) ? v : ""; };
function shelterList(all) { const m = new Map();
  for (const a of all) { const pk = String(a.animal_shelter_pkid || ""); if (!/^\d+$/.test(pk)) continue;
    const s = m.get(pk) || { pk, name: "", tel: "", addr: "", city: cityOf(a), dog: 0, cat: 0 };
    if (!s.name || (a.shelter_name && a.shelter_name.length > s.name.length)) s.name = a.shelter_name || a.animal_place || s.name;
    s.tel = s.tel || String(a.shelter_tel || "").trim(); s.addr = s.addr || String(a.shelter_address || "").trim();
    if (a.animal_kind === "貓") s.cat++; else s.dog++; m.set(pk, s); }
  return [...m.values()].filter((s) => s.name).sort((x, y) => y.dog + y.cat - x.dog - x.cat); }
function breeds(all) { const m = new Map();
  for (const a of all) { const b = breedOf(a); if (!b) continue; const k = (a.animal_kind === "貓" ? "貓" : "狗") + "|" + b; m.set(k, (m.get(k) || 0) + 1); }
  return [...m.entries()].filter(([, n]) => n >= 1).map(([k, n]) => ({ kind: k.split("|")[0], breed: k.split("|")[1], n })).sort((x, y) => y.n - x.n); }
const shelterLink = (s) => `${SITE}adopt/s/${s.pk}`;
const breedLink = (b) => `${SITE}adopt/b/${encodeURIComponent(b)}`;
const share = (url, text) => `<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px"><a class="btn ghost" style="flex:1;margin:0" target="_blank" rel="noopener" href="https://social-plugins.line.me/lineit/share?url=${encodeURIComponent(url)}">分享到 LINE</a><a class="btn ghost" style="flex:1;margin:0" target="_blank" rel="noopener" href="https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(url)}">分享到 Facebook</a></div><p class="meta" style="margin-top:6px;font-size:13px">${esc(text)}</p>`;
async function loadAll(waitUntil) { const [d, c] = await Promise.all([moaAdopt("狗", waitUntil), moaAdopt("貓", waitUntil)]); return d.concat(c); }

async function adoptShelterIndex(waitUntil) {
  const canonical = `${SITE}adopt/s/`;
  let all = [];
  try { all = await loadAll(waitUntil); } catch (_) { return down(canonical); }
  const ss = shelterList(all);
  const title = `全台動物收容所、動物之家一覽｜各縣市收容所電話、地址、待領養數量｜${NAME}`;
  const desc = `全台 ${ss.length} 間公立動物收容所、動物之家、流浪動物中途之家的電話與地址，依縣市整理。毛孩走失要打去哪一間、想領養狗狗貓咪去哪裡看，這裡一次查。資料每天更新。`.slice(0, 160);
  const by = CITIES.map((c) => [c, ss.filter((s) => s.city === c)]).filter(([, l]) => l.length);
  const body = `<h1>全台動物收容所、動物之家一覽</h1><p class="meta">${esc(`全台 ${ss.length} 間公立收容所的電話、地址和目前待領養的狗貓數量，依縣市整理，每天更新。`)}</p>
<p class="tip">毛孩走失了？請先打電話給走失地點所在縣市的收容所，問有沒有新收到；被路人送進收容所的狗貓，飼主常常不知道。<a href="${SITE}g/shelter-search">怎麼查收容所</a></p>
<nav class="cities">${by.map(([c]) => `<a href="#${encodeURIComponent(c)}">${c}</a>`).join("")}</nav>
${by.map(([c, l]) => `<h2 id="${encodeURIComponent(c)}">${c}動物收容所</h2>${l.map((s) => { const tel = s.tel.replace(/[^\d#+-]/g, "");
  return `<div class="card" style="margin-top:8px"><b><a href="${shelterLink(s)}">${esc(s.name)}</a></b><dl style="margin-top:6px">${s.tel ? `<dt>電話</dt><dd><a href="tel:${esc(tel)}">${esc(s.tel)}</a></dd>` : ""}${s.addr ? `<dt>地址</dt><dd>${esc(s.addr)}</dd>` : ""}<dt>待領養</dt><dd>狗 ${s.dog} 隻、貓 ${s.cat} 隻</dd></dl></div>`; }).join("")}
<p><a href="${SITE}adopt/${encodeURIComponent(c)}/${encodeURIComponent("狗")}">${c}待領養的狗狗</a>・<a href="${SITE}adopt/${encodeURIComponent(c)}/${encodeURIComponent("貓")}">${c}待領養的貓咪</a>・<a href="${SITE}l/${encodeURIComponent(c)}">${c}走失的毛孩</a></p>`).join("")}
<p class="meta" style="margin-top:18px;font-size:14px">資料來源：農業部動物認領養開放資料。這裡只列出目前有開放認養動物的收容所；開放時間各所不同，出發前請先打電話確認。</p>
<a class="btn" href="${SITE}#/new">我的毛孩走失了，免費登記協尋（每天自動比對收容所）</a>`;
  const jsonld = [{ "@context": "https://schema.org", "@type": "ItemList", name: "全台動物收容所", numberOfItems: ss.length, itemListElement: ss.slice(0, 100).map((s, i) => ({ "@type": "ListItem", position: i + 1, url: shelterLink(s), name: s.name })) },
    { "@context": "https://schema.org", "@type": "BreadcrumbList", itemListElement: [{ "@type": "ListItem", position: 1, name: NAME, item: SITE }, { "@type": "ListItem", position: 2, name: "領養", item: `${SITE}adopt/` }, { "@type": "ListItem", position: 3, name: "動物收容所一覽", item: canonical }] }];
  return resp(shell({ title, desc, canonical, body, jsonld }));
}

async function adoptShelter(pk, waitUntil) {
  if (!/^\d{1,4}$/.test(pk)) return notFound();
  const canonical = `${SITE}adopt/s/${pk}`;
  let all = [];
  try { all = await loadAll(waitUntil); } catch (_) { return down(canonical); }
  const s = shelterList(all).find((x) => x.pk === pk);
  if (!s) return notFound();
  const list = all.filter((a) => String(a.animal_shelter_pkid) === pk).sort((a, b) => (pic(b.album_file) ? 1 : 0) - (pic(a.album_file) ? 1 : 0));
  const tel = s.tel.replace(/[^\d#+-]/g, "");
  const title = `${s.name}｜電話、地址、領養｜待領養狗 ${s.dog} 隻、貓 ${s.cat} 隻${s.name.includes(s.city.slice(0, 2)) ? "" : "（" + s.city + "）"}｜${NAME}`;
  const desc = `${s.name}（${s.city}）目前有 ${s.dog} 隻狗、${s.cat} 隻貓開放領養。${s.tel ? "電話 " + s.tel + "。" : ""}${s.addr ? "地址 " + s.addr + "。" : ""}看照片、品種、收容編號。`.slice(0, 160);
  const map = s.addr ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(s.name + " " + s.addr)}` : "";
  const body = `<h1>${esc(s.name)}</h1><p class="meta">${esc(s.city)}・待領養狗狗 ${s.dog} 隻、貓咪 ${s.cat} 隻</p>
<div class="card"><dl>${s.tel ? `<dt>電話</dt><dd><a href="tel:${esc(tel)}">${esc(s.tel)}</a></dd>` : ""}${s.addr ? `<dt>地址</dt><dd>${map ? `<a target="_blank" rel="noopener" href="${esc(map)}">${esc(s.addr)}</a>` : esc(s.addr)}</dd>` : ""}</dl>
<p class="meta" style="margin:10px 0 0;font-size:14px">開放時間和領養流程各所不同，出發前請先打電話確認。毛孩走失時，也請打電話問這裡有沒有新收到。</p></div>
${list.length ? `<div class="grid">${list.slice(0, 400).map(itemHTML).join("")}</div>` : ""}
${JOIN}
${list.length > 400 ? `<a class="btn ghost" href="${SITE}#/adopt">看全部 ${list.length} 隻（汪喵回家領養頁）</a>` : ""}
<a class="btn ghost" href="${SITE}adopt/${encodeURIComponent(s.city)}/${encodeURIComponent("狗")}">${esc(s.city)}所有待領養的狗狗</a>
<a class="btn ghost" href="${SITE}adopt/${encodeURIComponent(s.city)}/${encodeURIComponent("貓")}">${esc(s.city)}所有待領養的貓咪</a>
<a class="btn ghost" href="${SITE}adopt/s/">全台動物收容所一覽（電話、地址）</a>`;
  const jsonld = { "@context": "https://schema.org", "@type": "AnimalShelter", name: s.name, telephone: s.tel || undefined, address: s.addr || undefined, url: canonical, areaServed: s.city };
  return resp(shell({ title, desc, canonical, image: list[0] && list[0].album_file, body, jsonld }));
}

const BFAQ = (b, kind, n) => [
  [`哪裡可以領養${b}？`, `全台公立收容所目前登記有 ${n} 隻${b}等待領養，這一頁每天更新。點進每一隻可以看到照片、性別、體型和收容所的電話地址，先打電話確認還在，再帶身分證過去。`],
  [`領養${b}要錢嗎？`, `公立收容所領養本身通常不收費，比購買省很多。依各縣市規定，可能要負擔晶片、寵物登記或狂犬病疫苗的費用，也有縣市提供免費或補助。`],
  [`收容所為什麼會有${b}？`, `品種${sp(kind)}也會走失或被棄養，被送進收容所後過了公告期沒有人認領，就會開放領養。收容所的品種是工作人員目測登記的，實際以現場看到的為準。`],
  [`現在沒有我想要的${b}怎麼辦？`, `收容所每天都有新的毛孩進來，可以把這一頁加到書籤常回來看，或到汪喵回家的領養頁用品種、年齡、縣市篩選。`]];
async function adoptBreed(b, waitUntil) {
  const canonical = `${SITE}adopt/b/${encodeURIComponent(b)}`;
  let all = [];
  try { all = await loadAll(waitUntil); } catch (_) { return down(canonical); }
  const list = all.filter((a) => breedOf(a) === b).sort((x, y) => (pic(y.album_file) ? 1 : 0) - (pic(x.album_file) ? 1 : 0));
  if (list.length < 1) return notFound();
  const kind = list[0].animal_kind === "貓" ? "貓" : "狗";
  const byCity = {}; list.forEach((a) => { const c = cityOf(a); if (c) byCity[c] = (byCity[c] || 0) + 1; });
  const cities = Object.entries(byCity).sort((x, y) => y[1] - x[1]);
  const title = `${b}領養｜全台收容所 ${list.length} 隻${b}待領養・免費認養・每日更新｜${NAME}`;
  const aka = /犬$/.test(b) ? `（${b.replace(/犬$/, "狗")}）` : "";
  const desc = `想領養${b}${aka}？全台公立收容所目前有 ${list.length} 隻${b}等待領養（${cities.slice(0, 4).map(([c, n]) => c + " " + n + " 隻").join("、")}）。看照片、性別、收容所電話，領養代替購買。`.slice(0, 160);
  const same = breeds(all).filter((x) => x.breed !== b && x.kind === kind).slice(0, 30);
  const faq = BFAQ(b, kind, list.length);
  const body = `<h1>${esc(b)}領養｜全台待領養的${esc(b)}</h1><p class="meta">${esc(desc)}</p>
<div class="grid">${list.slice(0, 300).map(itemHTML).join("")}</div>
<p class="tip">收容所的品種是工作人員目測登記的，實際以現場看到的為準。想領養前先打電話確認牠還在。</p>
${cities.length ? `<h2>各縣市的${esc(b)}</h2><nav class="cities">${cities.map(([c, n]) => `<a href="${SITE}adopt/${encodeURIComponent(c)}/${encodeURIComponent(kind)}">${esc(c)} ${n} 隻</a>`).join("")}</nav>` : ""}
${JOIN}
<h2>${esc(b)}領養常見問題</h2>${faq.map(([q, a]) => `<details class="card" style="margin-top:8px;padding:12px 16px"><summary style="font-weight:800;cursor:pointer">${esc(q)}</summary><p style="margin:8px 0 0">${esc(a)}</p></details>`).join("")}
<h2>其他${spWord(kind)}品種</h2><nav class="cities">${same.map((x) => `<a href="${breedLink(x.breed)}">${esc(x.breed)}（${x.n}）</a>`).join("")}</nav>
<a class="btn ghost" href="${SITE}adopt/b/">看全部品種</a>`;
  const jsonld = { "@context": "https://schema.org", "@graph": [
    { "@type": "CollectionPage", name: `${b}領養`, url: canonical, isPartOf: { "@type": "WebSite", name: NAME, url: SITE } },
    { "@type": "BreadcrumbList", itemListElement: [{ "@type": "ListItem", position: 1, name: "領養", item: `${SITE}adopt/` }, { "@type": "ListItem", position: 2, name: "依品種", item: `${SITE}adopt/b/` }, { "@type": "ListItem", position: 3, name: `${b}領養`, item: canonical }] },
    { "@type": "FAQPage", mainEntity: faq.map(([q, a]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a } })) }] };
  return resp(shell({ title, desc, canonical, image: list[0] && list[0].album_file, body, jsonld }));
}
async function adoptBreedIndex(waitUntil) {
  const canonical = `${SITE}adopt/b/`;
  let all = [];
  try { all = await loadAll(waitUntil); } catch (_) { return down(canonical); }
  const bs = breeds(all), dogs = bs.filter((x) => x.kind === "狗"), cats = bs.filter((x) => x.kind === "貓");
  const title = `品種狗、品種貓領養｜全台收容所 ${bs.length} 種品種待領養｜${NAME}`;
  const desc = `貴賓、柴犬、約克夏、法鬥、波斯貓…全台公立收容所目前有 ${dogs.length} 種品種狗、${cats.length} 種品種貓等待領養。依品種看照片與收容所電話，每天更新。`.slice(0, 160);
  const nav = (l) => `<nav class="cities">${l.map((x) => `<a href="${breedLink(x.breed)}">${esc(x.breed)}領養（${x.n}）</a>`).join("")}</nav>`;
  const body = `<h1>依品種找領養：品種狗、品種貓</h1><p class="meta">${esc(desc)}</p>
<h2>品種狗領養</h2>${nav(dogs)}<h2>品種貓領養</h2>${nav(cats)}
<p class="tip">收容所的品種是工作人員目測登記的；米克斯（混種）數量最多，請到各縣市頁面看。</p>
${JOIN}<a class="btn ghost" href="${SITE}adopt/">依縣市找領養</a>`;
  return resp(shell({ title, desc, canonical, body }));
}

// sitemap 用：所有待領養毛孩與縣市頁的網址
export async function adoptUrls(waitUntil) {
  const [d, c] = await Promise.all([moaAdopt("狗", waitUntil), moaAdopt("貓", waitUntil)]);
  const all = d.concat(c);
  return { animals: all.map((a) => ({ id: String(a.animal_id), t: String(a.animal_opendate || a.animal_createtime || "").replace(/\//g, "-").slice(0, 10) })),
    shelters: shelterList(all).map((x) => x.pk), breeds: [...new Set(breeds(all).map((x) => x.breed))] };
}

// 汪喵回家 — 給搜尋引擎看的頁面（Cloudflare Pages Functions，即時產生）
//   /p/<案件>       每一隻走失毛孩一頁：照片、特徵、走失地區、日期（Google 搜得到）
//   /l/<縣市>       這個縣市正在協尋的毛孩
//   /g/<指南>       協尋指南、毛孩小學堂的靜態文章（lib/guides.js）
//   /sitemap.xml    所有協尋中的毛孩、縣市頁、指南、待領養毛孩（lib/adopt.js）
// 只讀公開資料（publishable key，本來就公開在網頁裡）。
import { GUIDE_IDS } from "./guides.js";
import { adoptUrls, cityShelters, CITIES as ACITIES } from "./adopt.js";
import { TW, AGENCY } from "./twdata.js";
const SUPABASE_URL = "https://nopyhfpaykkiieudvoko.supabase.co";
const ANON_KEY = "sb_publishable_WCeVQIAPH0UEEzhTwovqkg_lJ8Qjydb";
const SITE = "https://wangmiaotw.com/";
const NAME = "汪喵回家";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const CITIES = ["臺北市","新北市","桃園市","臺中市","臺南市","高雄市","基隆市","新竹市","新竹縣","苗栗縣","彰化縣","南投縣","雲林縣","嘉義市","嘉義縣","屏東縣","宜蘭縣","花蓮縣","臺東縣","澎湖縣","金門縣","連江縣"];
const SP = { dog: ["狗", "尋狗啟事"], cat: ["貓", "尋貓啟事"] };
const SEX = { male: "男生", female: "女生" };
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

const CSS = `:root{--ink:#1A1A1A;--mute:#6F6A64;--red:#C2401F;--coral:#E8502E;--bg:#F7F6F4;--card:#fff;--line:#ECE9E5}
*{box-sizing:border-box}body{margin:0;font-family:system-ui,"PingFang TC","Noto Sans TC","Microsoft JhengHei",sans-serif;background:var(--bg);color:var(--ink);line-height:1.6}
a{color:var(--red)}header{display:flex;align-items:center;gap:10px;padding:14px 16px;max-width:960px;margin:0 auto}header a{display:flex;align-items:center;gap:8px;text-decoration:none;color:var(--ink);font-weight:800;font-size:20px}header img{width:34px;height:34px}
main{max-width:960px;margin:0 auto;padding:0 16px 40px}h1{font-size:26px;line-height:1.3;margin:8px 0 6px}.meta{color:var(--mute);margin:0 0 14px}
.hero{display:grid;gap:18px}@media(min-width:760px){.hero{grid-template-columns:1fr 1fr}}.ph{width:100%;aspect-ratio:1;object-fit:cover;border-radius:20px;background:#eee}
.card{background:var(--card);border-radius:22px;padding:18px 20px;box-shadow:0 10px 24px -18px rgba(60,40,20,.28)}dl{display:grid;grid-template-columns:auto 1fr;gap:6px 14px;margin:0}dt{color:var(--mute);font-weight:700}dd{margin:0}
.btn{display:block;text-align:center;background:linear-gradient(180deg,#F2643D,#DC4824);box-shadow:0 8px 18px -10px rgba(220,72,36,.7);color:#fff;text-decoration:none;font-weight:800;padding:14px;border-radius:16px;margin-top:12px}.btn.ghost{background:#fff;color:var(--ink);border:1.5px solid var(--line)}
.tip{background:#FFF6DC;border-radius:14px;padding:10px 14px;margin-top:12px;font-size:15px}.badge{display:inline-block;background:var(--red);color:#fff;border-radius:99px;padding:2px 10px;font-size:13px;font-weight:800}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;margin-top:12px}.it{display:block;text-decoration:none;color:var(--ink);background:var(--card);border-radius:16px;overflow:hidden}.it img,.it .np{width:100%;aspect-ratio:1;object-fit:cover;display:block;background:#EFEDEA}.it b{display:block;padding:8px 10px 0}.it small{display:block;padding:0 10px 10px;color:var(--mute)}
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
<footer>${NAME}｜全台走失狗貓協尋平台・免費・不收手續費<br><a href="${SITE}">回首頁</a>・<a href="${SITE}l/">各縣市走失毛孩</a>・<a href="${SITE}g/">協尋指南</a>・<a href="${SITE}adopt/">領養</a>・<a href="${SITE}rehome/">民眾送養</a>・<a href="${SITE}app">下載 App</a></footer></body></html>`;
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
<div class="card"><dl>${look ? `<dt>特徵</dt><dd>${esc(look)}</dd>` : ""}${c.features ? `<dt>辨識</dt><dd>${esc(c.features)}</dd>` : ""}${c.collar_desc ? `<dt>項圈</dt><dd>${esc(c.collar_desc)}</dd>` : ""}${c.temperament ? `<dt>個性</dt><dd>${esc(c.temperament)}</dd>` : ""}${c.age_text ? `<dt>年紀</dt><dd>${esc(c.age_text)}</dd>` : ""}<dt>晶片</dt><dd>${c.has_chip ? "有" : "無／不確定"}</dd>${Number(c.reward) > 0 ? `<dt>獎金</dt><dd>NT$${Number(c.reward).toLocaleString("en-US")}</dd>` : ""}</dl>
${searching ? `<p class="tip">看到${esc(c.name)}：<b>不要叫、不要追</b>，拍照記下時間地點，聯絡飼主。</p>` : ""}
${tel ? `<a class="btn" href="tel:${esc(tel)}">📞 看到毛孩了，打給飼主</a>` : ""}
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
const GUIDE_LINKS = `<h2>走失了怎麼辦？</h2><p><a href="${SITE}g/dog-lost">狗走失怎麼辦：黃金 48 小時</a>・<a href="${SITE}g/cat-lost">貓走失怎麼找</a>・<a href="${SITE}g/shelter-search">怎麼查收容所</a>・<a href="${SITE}g/found-pet">撿到狗貓怎麼辦</a>・<a href="${SITE}g/chip-lost-report">晶片遺失申報</a>・<a href="${SITE}g/shelter-claim">在收容所找到怎麼認領</a>・<a href="${SITE}g/lost-pet-channels">協尋管道整理</a>・<a href="${SITE}g/ai-find-pet">用 AI 照片比對找毛孩</a>・<a href="${SITE}g/about-wangmiao">汪喵回家是什麼</a></p>`;
export async function cityPage(parts, waitUntil) {
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
  if (dist && !(TW[city] || []).includes(dist)) return notFound();
  const cUrl = `${SITE}l/${encodeURIComponent(city)}`;
  let all = [];
  const shP = cityShelters(city, waitUntil);
  try { all = await q(`cases_public?status=eq.searching&lost_city=eq.${encodeURIComponent(city)}&select=id,name,species,lost_city,lost_district,lost_at,photos&order=last_activity.desc&limit=500`) || []; }
  catch (_) { return resp(shell({ title: NAME, desc: "", canonical: cUrl, body: "<p>暫時連不上資料，請稍後再試。</p>", noindex: true }), 503, undefined, 0); }
  const cnt = {}; for (const c of all) if (c.lost_district) cnt[c.lost_district] = (cnt[c.lost_district] || 0) + 1;
  const dnav = `<nav class="cities">${(TW[city] || []).map((d) => `<a href="${cUrl}/${encodeURIComponent(d)}"${d === dist ? ' style="background:var(--red);color:#fff"' : ""}>${esc(d)}${cnt[d] ? ` ${cnt[d]}` : ""}</a>`).join("")}</nav>`;
  const list = (dist ? all.filter((c) => c.lost_district === dist) : all).slice(0, 200);
  list.sort((a, b) => ((b.photos || []).length > 0) - ((a.photos || []).length > 0));
  const area = city + dist, url = dist ? `${cUrl}/${encodeURIComponent(dist)}` : cUrl;
  const dogs = list.filter((c) => c.species === "dog").length, cats = list.length - dogs;
  const ag = AGENCY[city], shel = (await shP).slice().sort((a, b) => (dist && b.name.includes(dist.slice(0, 2))) - (dist && a.name.includes(dist.slice(0, 2))));   // 同一區的收容所排最前面
  const agTxt = ag ? `${ag.n}（${ag.t.join("、")}）` : "當地的動物保護單位（全國動保專線 1959）";
  const telA = (p) => `<a href="tel:${esc(String(p).split(/[ （]/)[0].replace(/[^\d]/g, ""))}">${esc(p)}</a>`;
  const shTxt = shel.map((x) => x.name).join("、");
  const alt = /^臺/.test(city) ? city.replace(/^臺/, "台").replace(/[市縣]$/, "") + (dist ? dist.replace(/[區鄉鎮市]$/, "") : "") : "";   // 大家搜尋多半打「台南」「台中」
  const title = `${area}${alt ? `（${alt}）` : ""}狗不見了、貓走失怎麼辦？${list.length ? `目前 ${list.length} 隻在找・` : ""}協尋與附近收容所｜${NAME}`;
  const desc = `${alt ? alt + "、" : ""}${area}狗不見了、貓走失了怎麼辦？立刻在附近找、免費登記協尋、聯絡${ag ? ag.n : "動保單位"}與收容所。${list.length ? `${area}目前有 ${dogs} 隻狗、${cats} 隻貓正在協尋，` : ""}看到請不要追，拍照記下時間地點，聯絡飼主。`.slice(0, 160);
  const faq = [
    [`在${area}狗走失、貓走失了怎麼辦？`, `先回到走失地點附近找：狗多半還在 1 到 2 公里內，貓常躲在家附近的車底、樓梯間或草叢，帶毛孩熟悉的零食輕聲叫名字，不要追。接著到汪喵回家免費登記協尋，系統會做好協尋海報，讓${area}附近的人回報目擊，並每天比對全台收容所。也請打電話給${agTxt}${shTxt ? `，以及${shTxt}` : ""}，問有沒有收到長得像的毛孩。有植入晶片的話，記得到農業部寵物登記管理資訊網申報遺失。`],
    [`${alt || area}有沒有找走失狗貓的網站？要去哪裡登記協尋？`, `可以在汪喵回家（wangmiaotw.com，iPhone 在 App Store 搜尋「汪喵回家」）免費登記協尋。這一頁會列出${area}正在協尋的狗貓，路人看到可以直接回報目擊，系統也每天比對全台收容所與農業部遺失申報。也建議同時聯絡${agTxt}，並在${alt || area}的地區社團與 LINE 群組發協尋文。`],
    [`在${area}撿到或看到走失的狗貓，要怎麼處理？`, `先拍照、記下時間和位置，不要追。毛孩願意靠近的話，可以帶到附近的動物醫院或收容所免費掃晶片找飼主，也可以聯絡${agTxt}。也可以在汪喵回家登記拾獲或目擊，系統會自動比對附近正在找的走失毛孩。`],
    ...(shel.length ? [[`${city}有哪些收容所？`, shel.map((x) => `${x.name}${x.addr ? `（${x.addr}${x.tel ? `，電話 ${x.tel}` : ""}）` : x.tel ? `（電話 ${x.tel}）` : ""}`).join("；") + "。"]] : [])];
  const help = `<h2>毛孩在${esc(area)}走失了，先做這 4 件事</h2><ol>
<li><b>馬上回到走失地點附近找。</b>狗多半還在 1 到 2 公里內；貓常躲在家附近的車底、樓梯間、草叢。帶毛孩熟悉的零食輕聲叫名字，不要追。<a href="${SITE}g/dog-lost">狗走失怎麼辦</a>・<a href="${SITE}g/cat-lost">貓走失怎麼找</a></li>
<li><b>免費登記協尋。</b>汪喵回家會自動做好協尋海報，${esc(area)}附近的人看到可以直接回報給你，系統也會每天比對全台收容所。<a href="${SITE}#/new">現在登記</a></li>
<li><b>打給${esc(city)}的動保單位和收容所</b>，問有沒有收到長得像的毛孩：${ag ? `${esc(ag.n)} ${ag.t.map(telA).join("、")}` : `全國動保專線 ${telA("1959")}`}。<a href="${SITE}g/shelter-search">怎麼查收容所</a></li>
<li><b>有晶片的話，申報遺失。</b>到農業部寵物登記管理資訊網申報，收容所或動物醫院掃到晶片就能聯絡你。<a href="${SITE}g/chip-lost-report">晶片遺失申報教學</a></li></ol>
${shel.length ? `<h2>${esc(city)}的收容所</h2><div class="card"><dl>${shel.map((x) => `<dt>${esc(x.name)}</dt><dd>${x.tel ? telA(x.tel) : ""}${x.addr ? `${x.tel ? "　" : ""}${esc(x.addr)}` : ""}　<a href="${SITE}adopt/s/${x.pk}">看這裡的毛孩</a></dd>`).join("")}</dl></div>` : ""}
<h2>常見問題</h2>${faq.map(([qq, aa]) => `<h3 style="font-size:17px;margin:16px 0 4px">${esc(qq)}</h3><p style="margin:0">${esc(aa)}</p>`).join("")}`;
  const body = `<h1>${esc(area)}走失的狗狗、貓咪</h1><p class="meta">${esc(list.length ? `${area}目前有 ${dogs} 隻狗、${cats} 隻貓正在協尋。看到請不要追，拍照記下時間地點，聯絡飼主。` : `目前${area}沒有協尋中的走失毛孩。如果你的毛孩在${area}走失了，可以照下面的步驟找，並免費登記協尋。`)}</p>
${dist ? `<p><a href="${cUrl}">← ${esc(city)}全部走失毛孩</a></p>` : ""}
${list.length ? `<div class="grid">${list.map(itemHTML).join("")}</div>` : ""}
${dist && !list.length && all.length ? `<h2>${esc(city)}其他區正在找的毛孩</h2><p class="meta">走失的毛孩常會跑到隔壁區，出門時也幫忙留意。</p><div class="grid">${all.slice().sort((a, b) => ((b.photos || []).length > 0) - ((a.photos || []).length > 0)).slice(0, 12).map(itemHTML).join("")}</div>` : ""}
<a class="btn" href="${SITE}#/new">我的毛孩在${esc(area)}走失了，免費登記協尋</a>
<a class="btn ghost" href="${SITE}#/found/new">我在${esc(area)}撿到／看到走失的毛孩</a>
${help}<h2>${esc(city)}各區走失毛孩</h2>${dnav}
${GUIDE_LINKS}<h2>其他縣市</h2>${nav}`;
  const jsonld = { "@context": "https://schema.org", "@graph": [
    { "@type": "BreadcrumbList", itemListElement: [
      { "@type": "ListItem", position: 1, name: NAME, item: SITE },
      { "@type": "ListItem", position: 2, name: `${city}走失毛孩`, item: cUrl },
      ...(dist ? [{ "@type": "ListItem", position: 3, name: dist, item: url }] : [])] },
    { "@type": "FAQPage", mainEntity: faq.map(([qq, aa]) => ({ "@type": "Question", name: qq, acceptedAnswer: { "@type": "Answer", text: aa } })) }] };
  return resp(shell({ title, desc, canonical: url, body, jsonld }));
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
  const rh = await rehomeUrls();
  const d = (t) => String(t || "").slice(0, 10);
  const today = new Date().toISOString().slice(0, 10);   // 用 UTC 日期：台灣時間早 8 小時，Google 會當成「未來日期」
  const urls = [`<url><loc>${SITE}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>1.0</priority></url>`,
    `<url><loc>${SITE}app</loc><lastmod>${today}</lastmod><changefreq>monthly</changefreq><priority>0.8</priority></url>`,
    `<url><loc>${SITE}l/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.8</priority></url>`,
    ...CITIES.map((c) => `<url><loc>${SITE}l/${encodeURIComponent(c)}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`),
    ...CITIES.flatMap((c) => (TW[c] || []).map((d) => `${encodeURIComponent(c)}/${encodeURIComponent(d)}`)).map((x) => `<url><loc>${SITE}l/${x}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.6</priority></url>`),
    `<url><loc>${SITE}g/</loc><lastmod>${today}</lastmod><changefreq>weekly</changefreq><priority>0.8</priority></url>`,
    `<url><loc>${SITE}stats</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.8</priority></url>`,
    `<url><loc>${SITE}press</loc><lastmod>${today}</lastmod><changefreq>weekly</changefreq><priority>0.7</priority></url>`,
    ...GUIDE_IDS().map((g) => `<url><loc>${SITE}g/${g}</loc><lastmod>${today}</lastmod><changefreq>monthly</changefreq><priority>0.7</priority></url>`),
    `<url><loc>${SITE}adopt/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`,
    `<url><loc>${SITE}rehome/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`,
    ...rh.map((r) => `<url><loc>${SITE}rehome/${r.id}</loc><lastmod>${d(r.updated_at)}</lastmod><changefreq>weekly</changefreq><priority>0.6</priority>${(r.photos || []).slice(0, 2).map(okImg).filter(Boolean).map((u) => `<image:image><image:loc>${esc(u)}</image:loc></image:image>`).join("")}</url>`),
    `<url><loc>${SITE}adopt/b/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`,
    `<url><loc>${SITE}adopt/s/</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>`,
    ...ACITIES.flatMap((c) => ["狗", "貓"].map((k) => `<url><loc>${SITE}adopt/${encodeURIComponent(c)}/${encodeURIComponent(k)}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.6</priority></url>`)),
    ...adoptShel.map((pk) => `<url><loc>${SITE}adopt/s/${pk}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.6</priority></url>`),
    ...adoptBreeds.map((b) => `<url><loc>${SITE}adopt/b/${encodeURIComponent(b)}</loc><lastmod>${today}</lastmod><changefreq>daily</changefreq><priority>0.6</priority></url>`),
    ...adoptList.map((a) => `<url><loc>${SITE}adopt/a/${a.id}</loc>${/^\d{4}-\d\d-\d\d$/.test(a.t) && a.t >= "2015-01-01" ? `<lastmod>${a.t > today ? today : a.t}</lastmod>` : ""}<changefreq>weekly</changefreq><priority>0.5</priority></url>`),
    ...list.map((c) => `<url><loc>${SITE}p/${c.id}</loc><lastmod>${d(c.last_activity)}</lastmod><changefreq>daily</changefreq><priority>0.6</priority>${(c.photos || []).slice(0, 3).map(okImg).filter(Boolean).map((u) => `<image:image><image:loc>${esc(u)}</image:loc></image:image>`).join("")}</url>`)];
  return resp(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">\n${urls.join("\n")}\n</urlset>\n`, 200, "application/xml; charset=utf-8", 3600);
}

// llms-full.txt：網站說明＋常見問題＋全部指南＋目前正在協尋的毛孩（純文字，給 AI 助理讀）
export async function llmsFull(base) {
  const { guidesPlain } = await import("./guides.js");
  let cases = [];
  try { cases = await q(`cases_public?status=eq.searching&select=id,name,species,breed,sex,colour,lost_city,lost_district,lost_place,lost_at,features&order=last_activity.desc&limit=300`) || []; } catch (_) {}
  const SEXT = { male: "男生", female: "女生" };
  const byCity = {};
  for (const c of cases) (byCity[normCity(c.lost_city)] ||= []).push(c);
  const caseText = CITIES.filter((c) => byCity[c]).map((city) => `### ${city}（${byCity[city].length} 隻正在協尋）\n詳細：${SITE}l/${encodeURIComponent(city)}\n` +
    byCity[city].map((c) => `- ${c.name}：${[c.species === "cat" ? "貓" : "狗", c.breed, SEXT[c.sex], c.colour].filter(Boolean).join("・")}，${twDate(c.lost_at)} 在${c.lost_city}${c.lost_district || ""}${c.lost_place ? "（" + String(c.lost_place).slice(0, 30) + "）" : ""}走失。${c.features ? "特徵：" + String(c.features).replace(/\s+/g, " ").slice(0, 80) + "。" : ""}案件頁：${SITE}p/${c.id}`).join("\n")).join("\n\n");
  const today = twDate(new Date().toISOString());
  const body = `${base.trim()}

---

# 目前正在協尋的走失毛孩（更新：${today}，最近 ${cases.length} 筆）

看到請不要追，拍照、記下時間地點，到案件頁回報或直接聯絡飼主。各縣市、鄉鎮的完整列表：${SITE}l/

${caseText || "（暫時讀不到資料，請到 " + SITE + " 查看）"}

---

# 協尋指南與毛孩小學堂（全文）

${guidesPlain()}
`;
  return resp(body, 200, "text/plain; charset=utf-8", 3600);
}

// ===== 民眾送養：/rehome/（列表）、/rehome/<id>（每一隻一頁，分享時有照片預覽，開放申請中才給搜尋引擎收錄）=====
const RH_SEX = { male: "男生", female: "女生" };
const RH_DISC = "汪喵回家只是提供刊登和聯絡的平台，不是送養或領養的任何一方，不經手金錢，也不保證內容正確；雙方的約定、交接、費用和之後的照顧由送養人和領養人自己負責。";
const rhLoc = (r) => (r.city || "").replace(/^臺/, "台") + (r.district || "");
const rhSp = (r) => (r.species === "cat" ? "貓" : "狗");
function rhItem(r) {
  const ph = okImg((r.photos || [])[0]);
  return `<a class="it" href="${SITE}rehome/${r.id}">${ph ? `<img loading="lazy" src="${esc(thumb(ph))}" alt="${esc(`${rhLoc(r)}送養的${rhSp(r)}「${r.name}」`)}">` : '<div class="np"></div>'}<b>${esc(r.name)}</b><small>${esc([RH_SEX[r.sex], r.age_text, rhLoc(r)].filter(Boolean).join("・"))}</small></a>`;
}
export async function rehomeIndex() {
  let list = [];
  try { list = (await q(`rehomes_public?status=eq.open&updated_at=gte.${new Date(Date.now() - 120 * 864e5).toISOString()}&select=id,name,species,sex,age_text,city,district,photos,created_at&order=created_at.desc&limit=200`)) || []; }
  catch (_) { return resp(shell({ title: `民眾送養｜${NAME}`, desc: "", canonical: `${SITE}rehome/`, body: `<p>暫時連不上資料，請<a href="${SITE}#/rehome">打開民眾送養</a>。</p>`, noindex: true }), 503, undefined, 0); }
  const dogs = list.filter((r) => r.species === "dog").length, cats = list.length - dogs;
  const title = `民眾送養・免費領養狗貓｜由送養人親自審核｜${NAME}`;
  const desc = `全台民眾送養的狗狗、貓咪${list.length ? `，目前有 ${dogs} 隻狗、${cats} 隻貓在等一個家` : ""}。想領養的人填問卷，送養人親自審核、聊過再見面；禁止買賣，只收有收據的實際花費。`;
  const body = `<h1>民眾送養</h1><p class="meta">每一位領養人，都由送養人親自看過、聊過才決定。同意見面之前，雙方電話都不公開。</p>
<a class="btn" href="${SITE}#/rehome">打開民眾送養（申請領養、刊登送養）</a>
${list.length ? `<h2>正在等一個家（${list.length}）</h2><div class="grid">${list.map(rhItem).join("")}</div>` : `<p class="tip">目前還沒有民眾刊登送養。也可以看看<a href="${SITE}adopt/">全台收容所待領養的毛孩</a>。</p>`}
<h2>怎麼領養</h2><p>1. 看到喜歡的毛孩，按「我想領養」填問卷。2. 送養人看過問卷，覺得適合會回覆「再聊聊」，用站內訊息聊天。3. 同意見面後雙方才看到電話，約在公開場所見面。4. 交接時當面核對證件、簽認養切結書。</p>
<h2>想幫毛孩找新家</h2><p>刊登免費。你可以設定條件（家訪、切結書、回報近況、限定縣市），由你親自挑選領養人。依動物保護法，沒有許可不能販賣貓狗，只能收有收據的實際花費（上限 5,000 元）。</p>
<p class="meta" style="margin-top:18px">${esc(RH_DISC)}</p>
<p><a href="${SITE}adopt/">收容所待領養毛孩 →</a></p>`;
  const jsonld = { "@context": "https://schema.org", "@type": "CollectionPage", name: title, description: desc, url: `${SITE}rehome/`,
    mainEntity: { "@type": "ItemList", numberOfItems: list.length, itemListElement: list.slice(0, 50).map((r, i) => ({ "@type": "ListItem", position: i + 1, url: `${SITE}rehome/${r.id}`, name: r.name })) } };
  return resp(shell({ title, desc, canonical: `${SITE}rehome/`, image: (list[0] && list[0].photos || [])[0], body, jsonld }), 200, undefined, 300);
}
export async function rehomePage(id) {
  id = String(id || "").replace(/\.html$/, "");
  if (!UUID.test(id)) return notFound();
  let r;
  try { r = (await q(`rehomes_public?id=eq.${id}&select=id,species,name,sex,age_text,breed,neutered,vaccine,chip,temperament,health,story,photos,city,district,fee,fee_note,req_visit,req_contract,req_followup,req_cities,status,created_at&limit=1`))[0]; }
  catch (_) { return resp(shell({ title: NAME, desc: "", canonical: `${SITE}rehome/${id}`, body: `<p>暫時連不上資料，請<a href="${SITE}#/rehome/${id}">打開送養頁</a>。</p>`, noindex: true }), 503, undefined, 0); }
  if (!r) return resp(shell({ title: `這則送養已經下架｜${NAME}`, desc: "", canonical: `${SITE}rehome/${id}`, body: `<h1>這則送養已經下架了</h1><p><a href="${SITE}rehome/">看其他在等家的毛孩</a></p>`, noindex: true }), 404, undefined, 300);
  const open = r.status === "open", sp = rhSp(r), area = rhLoc(r);
  const look = [RH_SEX[r.sex], r.breed, r.age_text].filter(Boolean).join("・");
  const title = r.status === "adopted" ? `🎉 ${r.name}已經找到家了｜${NAME}` : `【${area}送養】${r.name}・${look || sp}｜${r.fee > 0 ? "實際花費" : "免費"}送養｜${NAME}`;
  const facts = [r.neutered === "yes" ? "已結紮" : r.neutered === "no" ? "未結紮" : "", r.vaccine === "yes" ? "疫苗已打" : "", r.chip === "yes" ? "有晶片" : ""].filter(Boolean);
  const desc = [`${area}民眾送養的${sp}「${r.name}」${look ? "，" + look : ""}`, facts.join("、"), r.temperament || "", open ? "想領養請填問卷，由送養人親自審核。" : ""].filter(Boolean).join("。").slice(0, 160);
  const ph = okImg((r.photos || [])[0]), more = (r.photos || []).slice(1, 6).map(okImg).filter(Boolean);
  const req = [r.req_visit ? "交接前家訪，或到領養人家裡交接" : "", r.req_contract ? "簽認養切結書、當面核對證件" : "", r.req_followup ? "接回去後回報近況照片" : "", (r.req_cities || []).length ? "只送養到：" + r.req_cities.map((x) => x.replace(/^臺/, "台")).join("、") : ""].filter(Boolean);
  const body = `${r.status === "adopted" ? '<span class="badge">找到家了</span>' : r.status === "paused" ? '<span class="badge">暫停申請</span>' : ""}
<h1>${esc(r.name)}</h1><p class="meta">📍 ${esc(area)}　${esc([sp === "貓" ? "貓咪" : "狗狗", look].filter(Boolean).join("・"))}　${esc(twDate(r.created_at))} 刊登</p>
<div class="hero">${ph ? `<img class="ph" src="${esc(ph)}" alt="${esc(`${area}送養的${sp}「${r.name}」`)}">` : ""}
<div class="card"><dl>${facts.length ? `<dt>健康</dt><dd>${esc(facts.join("、"))}</dd>` : ""}${r.temperament ? `<dt>個性</dt><dd>${esc(r.temperament)}</dd>` : ""}${r.health ? `<dt>狀況</dt><dd>${esc(r.health)}</dd>` : ""}<dt>費用</dt><dd>${r.fee > 0 ? `實際花費 NT$${Number(r.fee).toLocaleString("en-US")}（${esc(r.fee_note || "")}，附收據）` : "免費"}</dd></dl>
${req.length ? `<p class="tip">送養人的條件：${esc(req.join("；"))}</p>` : ""}
<a class="btn" href="${SITE}#/rehome/${id}">${open ? `我想領養${esc(r.name)}（填問卷）` : "打開送養頁"}</a></div></div>
${r.story ? `<h2>${esc(r.name)}的故事</h2><p>${esc(String(r.story).slice(0, 800))}</p>` : ""}
${more.length ? `<h2>更多照片</h2><div class="grid">${more.map((u, i) => `<span class="it"><img loading="lazy" src="${esc(thumb(u))}" alt="${esc(`${r.name} 照片 ${i + 2}`)}"></span>`).join("")}</div>` : ""}
<p class="meta" style="margin-top:18px">${esc(RH_DISC)}</p>
<p><a href="${SITE}rehome/">看其他在等家的毛孩 →</a>・<a href="${SITE}adopt/">收容所待領養</a></p>`;
  const jsonld = { "@context": "https://schema.org", "@graph": [
    { "@type": "WebPage", name: title, description: desc, ...(ph ? { image: ph } : {}), datePublished: r.created_at, url: `${SITE}rehome/${id}` },
    { "@type": "BreadcrumbList", itemListElement: [
      { "@type": "ListItem", position: 1, name: NAME, item: SITE },
      { "@type": "ListItem", position: 2, name: "民眾送養", item: `${SITE}rehome/` },
      { "@type": "ListItem", position: 3, name: r.name, item: `${SITE}rehome/${id}` }] }] };
  return resp(shell({ title, desc, canonical: `${SITE}rehome/${id}`, image: ph, body, noindex: !open, jsonld }));
}
export async function rehomeUrls() { try { return (await q(`rehomes_public?status=eq.open&updated_at=gte.${new Date(Date.now() - 120 * 864e5).toISOString()}&select=id,updated_at,photos&order=created_at.desc&limit=2000`)) || []; } catch (_) { return []; } }

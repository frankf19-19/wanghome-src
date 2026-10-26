// 汪喵回家 — 分享預覽頁（Cloudflare Pages Functions，每次有人打開連結時即時產生）
// 取代原本每 2 小時把分享頁 commit 進 GitHub 的做法：案件刪除或隱藏後，分享頁立刻消失，也不會留在 git 歷史。
// 只讀公開資料（publishable key，本來就公開在網頁裡）。
const SUPABASE_URL = "https://nopyhfpaykkiieudvoko.supabase.co";
const ANON_KEY = "sb_publishable_WCeVQIAPH0UEEzhTwovqkg_lJ8Qjydb";
const SITE_URL = "https://wangmiaotw.com/";
const SITE_NAME = "汪喵回家";
const SP = { dog: ["狗", "尋狗啟事", "犬"], cat: ["貓", "尋貓啟事", "貓"] };
const SEX = { male: "公", female: "母" };
const SIZE = { small: "小型", medium: "中型", large: "大型" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const okImg = (u) => typeof u === "string" && /^https:\/\/nopyhfpaykkiieudvoko\.supabase\.co\/storage\/v1\/object\/public\/photos\/[^\s'"()<>\\]+$/.test(u) ? u : "";

async function getOne(path, id, select) {
  const url = `${SUPABASE_URL}/rest/v1/${path}?id=eq.${id}&select=${select}&limit=1`;
  const r = await fetch(url, { headers: { apikey: ANON_KEY, Accept: "application/json" }, cf: { cacheTtl: 60 } });
  if (!r.ok) throw new Error("db " + r.status);
  const j = await r.json();
  return Array.isArray(j) ? j[0] || null : null;
}

function page(title, desc, image, target, canonical) {
  const t = esc(title), d = esc(desc), img = esc(okImg(image) || SITE_URL + "og.png"), tgt = esc(target);
  return `<!DOCTYPE html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${t}</title>
<meta name="description" content="${d}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="${esc(SITE_NAME)}">
<meta property="og:title" content="${t}">
<meta property="og:description" content="${d}">
<meta property="og:image" content="${img}">
<meta property="og:url" content="${esc(canonical)}">
<meta property="og:locale" content="zh_TW">
<meta property="og:image:alt" content="${t}">
<meta name="twitter:card" content="summary_large_image">
<link rel="canonical" href="${esc(canonical)}">
<link rel="icon" href="${SITE_URL}icon.svg" type="image/svg+xml">
<style>body{font-family:system-ui,"PingFang TC","Microsoft JhengHei",sans-serif;text-align:center;padding:40px 16px;color:#333}img{max-width:280px;border-radius:12px}a{color:#c8201f}</style>
</head><body>
<img src="${img}" alt=""><h1>${t}</h1><p>${d}</p><p><a href="${tgt}">前往${esc(SITE_NAME)}查看 →</a></p>
<script>location.replace(${JSON.stringify(target).replace(/</g, "\\u003c")});</script>
</body></html>`;
}

const html = (body, status = 200, maxAge = 300) => new Response(body, { status, headers: {
  "content-type": "text/html; charset=utf-8", "cache-control": `public, max-age=${maxAge}`,
  "x-content-type-options": "nosniff", "referrer-policy": "strict-origin-when-cross-origin",
  "access-control-allow-origin": "*" } });   // App 裡要先檢查分享頁存不存在（跨網域）
// 找不到（刪除、隱藏或網址錯）：直接帶回首頁，不透露任何資料
const gone = (hash) => html(page(`${SITE_NAME}｜全台走失毛孩協尋平台`, "這個頁面已經不存在，可能已經找到或結案了。", "", SITE_URL + hash, SITE_URL), 404, 60);

function twDate(ts) {
  try { const d = new Date(new Date(ts).getTime() + 8 * 3600e3); return `${d.getUTCMonth() + 1}/${d.getUTCDate()}`; } catch (_) { return ""; }
}

export async function caseShare(id) {
  id = String(id || "").replace(/\.html$/, "");
  if (!UUID.test(id)) return gone("");
  let c;
  try { c = await getOne("cases_public", id, "id,species,name,status,breed,sex,size,colour,features,lost_city,lost_district,lost_place,lost_at,photos,reward"); }
  catch (_) { return html(page(SITE_NAME, "", "", `${SITE_URL}#/case/${id}`, `${SITE_URL}s/${id}`), 200, 30); }   // 資料庫暫時連不上：照樣帶過去
  if (!c) return gone("");
  const [, poster, unit] = SP[c.species] || SP.dog;
  let title;
  if (c.status === "found") title = `🎉 ${c.name} 已經找到了！｜${SITE_NAME}`;
  else if (c.status !== "searching") title = `${c.name}（協尋已結束）｜${SITE_NAME}`;
  else { const w = twDate(c.lost_at); title = `【${poster}】${c.name}｜${c.lost_city}${c.lost_district || ""}${w ? `・${w} 走失` : ""}`; }
  const look = [c.breed, SEX[c.sex], c.size ? (SIZE[c.size] || "") + unit : null, c.colour].filter(Boolean).join("・");
  const bits = [look, c.features || ""];
  if (c.reward) bits.push(`尋獲獎金 NT$${Number(c.reward).toLocaleString("en-US")}`);
  if (c.lost_place) bits.push("走失地點：" + c.lost_place);
  if (c.status === "searching") bits.push("看到請勿呼喊追趕，拍照記下時間地點，點連結回報目擊。");
  const desc = bits.filter(Boolean).join("　").slice(0, 190);
  return html(page(title, desc, (c.photos || [])[0], `${SITE_URL}#/case/${id}`, `${SITE_URL}s/${id}`));
}

export async function foundShare(id) {
  id = String(id || "").replace(/\.html$/, "");
  if (!UUID.test(id)) return gone("");
  let f;
  try { f = await getOne("found_public", id, "id,species,kind,status,colour,size,city,district,place_text,photos,current_place,injury"); }
  catch (_) { return html(page(SITE_NAME, "", "", `${SITE_URL}#/found/${id}`, `${SITE_URL}f/${id}`), 200, 30); }
  if (!f) return gone("");
  const [name] = SP[f.species] || SP.dog;
  const kind = f.kind === "injured" ? "受傷" : f.kind === "found" ? "拾獲" : "目擊";
  const tail = f.status === "open" ? "這是你的毛孩嗎？" : f.status === "reunited" ? "已經回到主人身邊" : "通報已結束";
  const title = `【${kind}${name}】${SIZE[f.size] || ""}${f.colour || ""}${name}｜${f.city}${f.district || ""}｜${tail}`;
  const bits = [f.injury ? "傷勢：" + f.injury : "", f.place_text || "", f.current_place ? "目前在：" + f.current_place : "", "點連結看照片並聯絡通報者。"];
  const desc = bits.filter(Boolean).join("　").slice(0, 190);
  return html(page(title, desc, (f.photos || [])[0], `${SITE_URL}#/found/${id}`, `${SITE_URL}f/${id}`));
}

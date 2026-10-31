// 收容所照片轉接（給排程主機用：寵物登記網不接受國外直接連線）。只接受農業部的照片網址，快取 7 天。
// GET /api/petimg?u=https://www.pet.gov.tw/upload/pic/xxx.png
const OK = /^https:\/\/(www\.pet\.gov\.tw|asms\.moa\.gov\.tw|asms\.coa\.gov\.tw)\/[^\s'"<>\\]+$/i;
export async function onRequestGet({ request, waitUntil }) {
  const U = new URL(request.url), u = U.searchParams.get("u") || "", dbg = U.searchParams.has("d");
  const cors = { "Access-Control-Allow-Origin": "*" };
  if (!OK.test(u)) return new Response("bad", { status: 400, headers: cors });
  const key = new Request("https://wangmiaotw.com/api/petimg/v2/" + encodeURIComponent(u));
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit && !dbg) return new Response(hit.body, { status: hit.status, headers: hit.headers });
  let r;
  // 寵物登記網偶爾連不上（522）：最多試 3 次
  for (let i = 0; i < 3; i++) {
    try { r = await fetch(u, { headers: { "User-Agent": "Mozilla/5.0 (compatible; WangMiaoHome/1.0; +https://wangmiaotw.com)", "Referer": "https://www.pet.gov.tw/AnimalApp/AnnounceMent_Announce.aspx", "Accept": "image/*" } }); }
    catch (_) { r = null; }
    if (r && r.status < 500) break;
    await new Promise((res) => setTimeout(res, 800 * (i + 1)));
  }
  if (!r || r.status >= 500) return new Response("upstream", { status: 502, headers: cors });
  const ct = r.headers.get("Content-Type") || "";
  if (dbg) return new Response(JSON.stringify({ st: r.status, ct, len: (await r.arrayBuffer()).byteLength }), { headers: cors });
  if (!r.ok || !/^(image\/|application\/octet-stream)/.test(ct)) return new Response("Not found", { status: 404, headers: { ...cors, "Cache-Control": "no-store" } });
  const body = await r.arrayBuffer();
  const out = new Response(body, { status: 200, headers: { ...cors, "Content-Type": ct.startsWith("image/") ? ct : "image/jpeg", "Cache-Control": "public, max-age=604800" } });
  waitUntil(cache.put(key, out.clone()));
  return out;
}

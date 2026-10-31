// 收容所公告照片轉接：農業部開放資料裡剛入所的動物常常沒有照片，但收容公告頁上有。
// 讀公告頁找出照片網址，再把照片轉給網站（加跨網域標頭、快取 7 天；找不到快取 6 小時，等收容所補照片）。
// GET /api/shelterpic/AAAIG1151029003.jpg
export async function onRequestGet({ params, waitUntil, request }) {
  const dbg = false, dl = [];
  const sub = String(params.id || "").replace(/\.jpg$/, "");
  const cors = { "Access-Control-Allow-Origin": "*" };
  if (!/^[A-Z]{5}[0-9]{6,20}$/.test(sub)) return new Response("Not found", { status: 404, headers: cors });
  const key = new Request(`https://wangmiaotw.com/api/shelterpic/v3/${sub}.jpg`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit && !dbg) return new Response(hit.body, { status: hit.status, headers: hit.headers });
  const nf = () => { const r = new Response("Not found", { status: 404, headers: { ...cors, "Cache-Control": "public, max-age=3600" } }); waitUntil(cache.put(key, r.clone())); return r; };
  const ua = { "User-Agent": "Mozilla/5.0 (compatible; WangMiaoHome/1.0; +https://wangmiaotw.com)" };
  let pic = "";
  try {
    for (const pt of ["Announce", "Adopt"]) {
      const u = `https://www.pet.gov.tw/AnimalApp/AnnounceSingle.aspx?PageType=${pt}&AcNum=${encodeURIComponent(btoa(sub))}&UT=${encodeURIComponent(btoa(sub.slice(0, 5)))}`;
      const r = await fetch(u, { headers: ua, redirect: "follow" });
      const html = await r.text();
      if (dbg) dl.push([pt, r.status, html.length, html.slice(0, 120)]);
      if (!r.ok) continue;
      const m = html.match(/og:image"\s+content="(https:\/\/www\.pet\.gov\.tw\/Upload\/pic\/[A-Za-z0-9_\-]+\.(?:png|jpe?g|gif|webp))"/i);
      if (m) { pic = m[1]; break; }
    }
  } catch (_) { return new Response("upstream", { status: 502, headers: cors }); }
  if (!pic) return dbg ? new Response(JSON.stringify({ pic, dl })) : nf();
  let r;
  try { r = await fetch(pic, { headers: { ...ua, "Referer": "https://www.pet.gov.tw/AnimalApp/AnnounceMent_Announce.aspx", "Accept": "image/*" } }); } catch (e) { return new Response("upstream " + (dbg ? String(e) : ""), { status: 502, headers: cors }); }
  const ct = r.headers.get("Content-Type") || "image/jpeg";
  if (dbg) { const b = await r.arrayBuffer(); return new Response(JSON.stringify({ pic, dl, img: [r.status, ct, b.byteLength] }), { headers: { ...cors, "Content-Type": "application/json" } }); }
  if (!r.ok || !/^(image\/(jpeg|png|webp|gif)|application\/octet-stream)/i.test(ct)) return nf();
  const body = await r.arrayBuffer();
  if (body.byteLength < 500) return nf();
  const out = new Response(body, { status: 200, headers: { ...cors, "Content-Type": /^image\/(jpeg|png|webp|gif)/i.test(ct) ? ct : "image/jpeg", "Cache-Control": "public, max-age=604800", "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'; sandbox" } });
  waitUntil(cache.put(key, out.clone()));
  return out;
}

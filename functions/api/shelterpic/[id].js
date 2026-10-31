// 收容所公告照片轉接：農業部開放資料裡剛入所的動物常常沒有照片，但收容公告頁上有。
// 讀公告頁找出照片網址，再把照片轉給網站（加跨網域標頭、快取 7 天；找不到快取 6 小時，等收容所補照片）。
// GET /api/shelterpic/AAAIG1151029003.jpg
export async function onRequestGet({ params, waitUntil }) {
  const sub = String(params.id || "").replace(/\.jpg$/, "");
  const cors = { "Access-Control-Allow-Origin": "*" };
  if (!/^[A-Z]{5}[0-9]{6,20}$/.test(sub)) return new Response("Not found", { status: 404, headers: cors });
  const key = new Request(`https://wangmiaotw.com/api/shelterpic/${sub}.jpg`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) return new Response(hit.body, { status: hit.status, headers: hit.headers });
  const nf = () => { const r = new Response("Not found", { status: 404, headers: { ...cors, "Cache-Control": "public, max-age=21600" } }); waitUntil(cache.put(key, r.clone())); return r; };
  const ua = { "User-Agent": "Mozilla/5.0 (compatible; WangMiaoHome/1.0; +https://wangmiaotw.com)" };
  let pic = "";
  try {
    for (const pt of ["Announce", "Adopt"]) {
      const u = `https://www.pet.gov.tw/AnimalApp/AnnounceSingle.aspx?PageType=${pt}&AcNum=${encodeURIComponent(btoa(sub))}&UT=${encodeURIComponent(btoa(sub.slice(0, 5)))}`;
      const r = await fetch(u, { headers: ua });
      if (!r.ok) continue;
      const html = await r.text();
      const m = html.match(/(?:https:\/\/www\.pet\.gov\.tw)?\/?Upload\/pic\/[A-Za-z0-9_\-]+\.(?:png|jpe?g|gif|webp)/i);
      if (m) { pic = m[0].startsWith("http") ? m[0] : "https://www.pet.gov.tw/" + m[0].replace(/^\//, ""); break; }
    }
  } catch (_) { return new Response("upstream", { status: 502, headers: cors }); }
  if (!pic) return nf();
  let r;
  try { r = await fetch(pic, { headers: ua }); } catch (_) { return new Response("upstream", { status: 502, headers: cors }); }
  const ct = r.headers.get("Content-Type") || "image/jpeg";
  if (!r.ok || !/^image\//.test(ct)) return nf();
  const body = await r.arrayBuffer();
  if (body.byteLength < 500) return nf();
  const out = new Response(body, { status: 200, headers: { ...cors, "Content-Type": ct, "Cache-Control": "public, max-age=604800" } });
  waitUntil(cache.put(key, out.clone()));
  return out;
}

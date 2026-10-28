// App 用的地圖圖磚轉接：App 裡的網頁沒有網址來源，直接向 OpenStreetMap 要圖會被擋，
// 改由這裡帶上本站的識別資訊去要，並在 Cloudflare 快取 30 天（同一張圖不重複要）。
// 只給台灣附近的範圍。GET /api/tile/{z}/{x}/{y}.png
const ALLOW = ["capacitor://localhost", "https://localhost", "https://wangmiaotw.com", "https://www.wangmiaotw.com"];
const lon2x = (lon, z) => Math.floor(((lon + 180) / 360) * 2 ** z);
const lat2y = (lat, z) => { const r = (lat * Math.PI) / 180; return Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * 2 ** z); };

export async function onRequestGet({ params, request, waitUntil }) {
  const z = Number(params.z), x = Number(params.x), y = Number(String(params.y).replace(/\.png$/, ""));
  const origin = request.headers.get("Origin") || "";
  const cors = { "Access-Control-Allow-Origin": ALLOW.includes(origin) ? origin : "*" };
  const bad = () => new Response("Not found", { status: 404, headers: cors });
  if (![z, x, y].every(Number.isInteger) || z < 5 || z > 19) return bad();
  // 台灣附近（含澎湖、金門、馬祖），多留一點邊
  const x0 = lon2x(116.5, z), x1 = lon2x(123.5, z), y0 = lat2y(27.0, z), y1 = lat2y(21.0, z);
  if (x < x0 || x > x1 || y < y0 || y > y1) return bad();
  const key = new Request(`https://wangmiaotw.com/api/tile/${z}/${x}/${y}.png`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) { const h = new Headers(hit.headers); Object.entries(cors).forEach(([k, v]) => h.set(k, v)); return new Response(hit.body, { status: 200, headers: h }); }
  let r;
  try {
    r = await fetch(`https://tile.openstreetmap.org/${z}/${x}/${y}.png`, {
      headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com; service@wangmiaotw.com)", "Referer": "https://wangmiaotw.com/" },
      cf: { cacheTtl: 2592000, cacheEverything: true },
    });
  } catch (_) { return new Response("upstream", { status: 502, headers: cors }); }
  if (!r.ok) return new Response("upstream", { status: 502, headers: cors });
  const body = await r.arrayBuffer();
  const out = new Response(body, { status: 200, headers: { "Content-Type": "image/png", "Cache-Control": "public, max-age=2592000, immutable" } });
  waitUntil(cache.put(key, out.clone()));
  const h = new Headers(out.headers); Object.entries(cors).forEach(([k, v]) => h.set(k, v));
  return new Response(body, { status: 200, headers: h });
}

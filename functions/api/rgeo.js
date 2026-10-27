// 地址反查轉接：App 裡的網頁沒有網址來源，直接查 OpenStreetMap（Nominatim）可能被擋，
// 改由這裡帶上本站的識別資訊去查，並快取 30 天（同一個點不重複查）。
// GET /api/rgeo?lat=25.03300&lon=121.56540
const ALLOW = ["capacitor://localhost", "https://localhost", "https://wangmiaotw.com", "https://www.wangmiaotw.com"];

export async function onRequestGet({ request, waitUntil }) {
  const url = new URL(request.url);
  const origin = request.headers.get("Origin") || "";
  const cors = { "Access-Control-Allow-Origin": ALLOW.includes(origin) ? origin : "https://wangmiaotw.com", "Vary": "Origin" };
  const lat = Number(url.searchParams.get("lat")), lon = Number(url.searchParams.get("lon"));
  // 只查台灣附近，座標取到小數 4 位（約 10 公尺），也讓快取比較容易命中
  if (!Number.isFinite(lat) || !Number.isFinite(lon) || lat < 20 || lat > 27.5 || lon < 116 || lon > 123.5) {
    return new Response(JSON.stringify({ error: "bad_coords" }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
  }
  const la = lat.toFixed(4), lo = lon.toFixed(4);
  const key = new Request(`https://wangmiaotw.com/api/rgeo?lat=${la}&lon=${lo}`);
  const cache = caches.default;
  let hit = await cache.match(key);
  if (hit) {
    const h = new Headers(hit.headers); Object.entries(cors).forEach(([k, v]) => h.set(k, v));
    return new Response(hit.body, { status: hit.status, headers: h });
  }
  let r;
  try {
    r = await fetch(`https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${la}&lon=${lo}&zoom=18&accept-language=zh-TW`, {
      headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com; service@wangmiaotw.com)", "Referer": "https://wangmiaotw.com/", "Accept": "application/json" },
      cf: { cacheTtl: 2592000, cacheEverything: true },
    });
  } catch (_) {
    return new Response(JSON.stringify({ error: "upstream" }), { status: 502, headers: { ...cors, "Content-Type": "application/json" } });
  }
  if (!r.ok) return new Response(JSON.stringify({ error: "upstream", status: r.status }), { status: 502, headers: { ...cors, "Content-Type": "application/json" } });
  const body = await r.text();
  const out = new Response(body, { status: 200, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=2592000" } });
  waitUntil(cache.put(key, out.clone()));
  const h = new Headers(out.headers); Object.entries(cors).forEach(([k, v]) => h.set(k, v));
  return new Response(body, { status: 200, headers: h });
}

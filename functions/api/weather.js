// 散步日記用的「現在天氣」：轉接 Open-Meteo（免金鑰），回傳氣溫和天氣代碼。
// 座標只取到小數 2 位（約 1 公里）再送出去，同一個地方 15 分鐘內不重複查。
// GET /api/weather?lat=25.03&lon=121.56  →  {"t":27.4,"code":2}
const ALLOW = ["capacitor://localhost", "https://localhost", "https://wangmiaotw.com", "https://www.wangmiaotw.com"];

export async function onRequestGet({ request, waitUntil }) {
  const url = new URL(request.url);
  const origin = request.headers.get("Origin") || "";
  const cors = { "Access-Control-Allow-Origin": ALLOW.includes(origin) ? origin : "https://wangmiaotw.com", "Vary": "Origin" };
  const json = (o, status = 200, extra = {}) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json; charset=utf-8", ...extra } });
  const lat = Number(url.searchParams.get("lat")), lon = Number(url.searchParams.get("lon"));
  if (!url.searchParams.get("lat") || !url.searchParams.get("lon") || !Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat) > 85 || Math.abs(lon) > 180) return json({ error: "bad_coords" }, 400);
  const la = lat.toFixed(2), lo = lon.toFixed(2);
  const key = new Request(`https://wangmiaotw.com/api/weather?lat=${la}&lon=${lo}`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) { const h = new Headers(hit.headers); Object.entries(cors).forEach(([k, v]) => h.set(k, v)); return new Response(hit.body, { status: 200, headers: h }); }
  let r;
  try { r = await fetch(`https://api.open-meteo.com/v1/forecast?latitude=${la}&longitude=${lo}&current=temperature_2m,weather_code&timezone=auto`, { headers: { "Accept": "application/json" } }); }
  catch (_) { return json({ error: "upstream" }, 502); }
  if (!r.ok) return json({ error: "upstream", status: r.status }, 502);
  let j; try { j = await r.json(); } catch (_) { return json({ error: "upstream" }, 502); }
  const c = j && j.current;
  if (!c || typeof c.temperature_2m !== "number" || typeof c.weather_code !== "number") return json({ error: "nodata" }, 502);
  const body = JSON.stringify({ t: Math.round(c.temperature_2m * 10) / 10, code: c.weather_code });
  const out = new Response(body, { status: 200, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=900" } });
  waitUntil(cache.put(key, out.clone()));
  return new Response(body, { status: 200, headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=900" } });
}

// 走失地點附近「先找這些地方」：代查 OpenStreetMap（Overpass），並快取 14 天。
// 直接從瀏覽器查常常要等十幾秒；改由這裡查，同一個地點查過一次之後就是即時的。App 裡也只要連本站就好。
// GET /api/spots?lat=25.0330&lng=121.5654&r=1000
const ALLOW = ["capacitor://localhost", "https://localhost", "https://wangmiaotw.com", "https://www.wangmiaotw.com"];
const EPS = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"];

export async function onRequestGet({ request, waitUntil }) {
  const url = new URL(request.url);
  const origin = request.headers.get("Origin") || "";
  const cors = { "Access-Control-Allow-Origin": ALLOW.includes(origin) ? origin : "https://wangmiaotw.com", "Vary": "Origin" };
  const json = (o, status, extra = {}) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json; charset=utf-8", ...extra } });
  const lat = Number(url.searchParams.get("lat")), lng = Number(url.searchParams.get("lng"));
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || lat < 20 || lat > 27.5 || lng < 116 || lng > 123.5) return json({ error: "bad_coords" }, 400);
  // 座標取到小數 3 位（約 100 公尺）、半徑取 250 公尺一級：附近的案件可以共用快取
  const la = lat.toFixed(3), lo = lng.toFixed(3);
  const r = Math.min(2000, Math.max(250, Math.round((Number(url.searchParams.get("r")) || 1000) / 250) * 250));
  const key = new Request(`https://wangmiaotw.com/api/spots?lat=${la}&lng=${lo}&r=${r}`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) { const h = new Headers(hit.headers); Object.entries(cors).forEach(([k, v]) => h.set(k, v)); return new Response(hit.body, { status: 200, headers: h }); }
  const q = `[out:json][timeout:20];(nwr(around:${r},${la},${lo})[leisure~"^(park|playground|garden)$"][name];nwr(around:${r},${la},${lo})[amenity~"^(school|marketplace|place_of_worship)$"][name];nwr(around:${r},${la},${lo})[waterway~"^(river|stream|canal)$"][name];nwr(around:4000,${la},${lo})[amenity=veterinary];);out center tags 80;`;
  let data = null;
  for (const ep of EPS) {
    try {
      const res = await fetch(ep, { method: "POST", body: "data=" + encodeURIComponent(q), signal: AbortSignal.timeout(22000),
        headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com; service@wangmiaotw.com)" } });
      if (!res.ok) continue;
      const j = await res.json();
      if (j && Array.isArray(j.elements)) { data = j; break; }
    } catch (_) { /* 換下一台 */ }
  }
  if (!data) return json({ error: "upstream" }, 502);
  // 只留前端用得到的欄位
  const KEEP = ["name", "leisure", "amenity", "waterway", "phone", "contact:phone"];
  const elements = data.elements.map((e) => ({ lat: e.lat ?? e.center?.lat, lon: e.lon ?? e.center?.lon, tags: Object.fromEntries(KEEP.filter((k) => e.tags && e.tags[k]).map((k) => [k, e.tags[k]])) })).filter((e) => e.lat != null);
  const body = JSON.stringify({ elements });
  waitUntil(cache.put(key, new Response(body, { status: 200, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=1209600" } })));
  return new Response(body, { status: 200, headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=86400" } });
}

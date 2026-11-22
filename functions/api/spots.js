// 走失地點附近「先找這些地方」：代查 OpenStreetMap，並快取 14 天。
// 直接從瀏覽器查常常要等十幾秒；改由這裡查，同一個地點查過一次之後就是即時的。App 裡也只要連本站就好。
// GET /api/spots?lat=25.0330&lng=121.5654&r=1000
const ALLOW = ["capacitor://localhost", "https://localhost", "https://wangmiaotw.com", "https://www.wangmiaotw.com"];

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
  // 用 OpenStreetMap 的 Nominatim 分類查詢（Overpass 從雲端主機查常常逾時）：公園、學校、市場、宮廟在範圍內找，動物醫院找遠一點
  const box = (m) => { const dLat = m / 111000, dLng = m / (111000 * Math.cos(lat * Math.PI / 180)); return `${(lng - dLng).toFixed(4)},${(lat + dLat).toFixed(4)},${(lng + dLng).toFixed(4)},${(lat - dLat).toFixed(4)}`; };
  const CATS = [["park", r], ["school", r], ["place of worship", r], ["marketplace", r], ["veterinary", 4000]];
  const elements = []; const errs = []; let ok = 0;
  for (const [q, m] of CATS) {
    try {
      const res = await fetch(`https://nominatim.openstreetmap.org/search?format=jsonv2&q=${encodeURIComponent(q)}&viewbox=${box(m)}&bounded=1&limit=15&extratags=1&accept-language=zh-TW`, {
        headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com; service@wangmiaotw.com)", "Referer": "https://wangmiaotw.com/", "Accept": "application/json" }, signal: AbortSignal.timeout(8000) });
      if (!res.ok) { errs.push(q + " " + res.status); continue; }
      ok++;
      for (const x of await res.json()) {
        if (!x || !x.lat || !["leisure", "amenity"].includes(x.category)) continue;
        const tags = { [x.category]: x.type }; if (x.name) tags.name = x.name;
        const ph = x.extratags && (x.extratags.phone || x.extratags["contact:phone"]); if (ph) tags.phone = ph;
        elements.push({ lat: +x.lat, lon: +x.lon, tags });
      }
    } catch (e) { errs.push(q + " " + String(e).slice(0, 60)); }
  }
  if (!ok) return json({ error: "upstream", errs }, url.searchParams.get("debug") ? 200 : 503);
  const body = JSON.stringify({ elements });
  waitUntil(cache.put(key, new Response(body, { status: 200, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=1209600" } })));
  return new Response(body, { status: 200, headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=86400" } });
}

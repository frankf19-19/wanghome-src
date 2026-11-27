// 散步冒險的「真實地圖」資料：從 OpenStreetMap（Overpass）抓附近的公園、遊樂場、飲水站、狗狗公園，以及可以走的小路。
// 以約 550 公尺的方格為單位快取 7 天：同一區第二個人來就不用再查，Overpass 忙的時候也不影響。
// GET /api/osm?lat=25.04&lon=121.56 → {"t":"格子","st":[[id,種類,緯度,經度,名稱]],"w":[[緯,經,緯,經,…]]}
const ALLOW = ["capacitor://localhost", "https://localhost", "https://wangmiaotw.com", "https://www.wangmiaotw.com"];
const STEP = 0.005;
const UP = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter", "https://overpass.private.coffee/api/interpreter", "https://maps.mail.ru/osm/tools/overpass/api/interpreter"];

export async function onRequestGet({ request, waitUntil }) {
  const url = new URL(request.url);
  const origin = request.headers.get("Origin") || "";
  const cors = { "Access-Control-Allow-Origin": ALLOW.includes(origin) ? origin : "https://wangmiaotw.com", "Vary": "Origin" };
  const json = (body, status = 200, extra = {}) => new Response(typeof body === "string" ? body : JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json; charset=utf-8", ...extra } });
  const lat = Number(url.searchParams.get("lat")), lon = Number(url.searchParams.get("lon"));
  if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat) > 85 || Math.abs(lon) > 180) return json({ error: "bad_coords" }, 400);
  const ty = Math.floor(lat / STEP), tx = Math.floor(lon / STEP), tile = `${ty}_${tx}`;
  const s = (ty * STEP).toFixed(4), w = (tx * STEP).toFixed(4), n = ((ty + 1) * STEP).toFixed(4), e = ((tx + 1) * STEP).toFixed(4);
  const key = new Request(`https://wangmiaotw.com/api/osm?tile=${tile}&v=1`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) return json(await hit.text(), 200, { "Cache-Control": "public, max-age=86400", "X-Cache": "HIT" });
  const bb = `${s},${w},${n},${e}`;
  const q = `[out:json][timeout:25];(nwr["leisure"~"^(park|dog_park|playground)$"](${bb});node["amenity"="drinking_water"](${bb}););out center 80;way["highway"~"^(footway|path|pedestrian|living_street|residential|service|cycleway|track|steps)$"](${bb});out geom 500;`;
  let j = null;
  for (const ep of UP) {
    try {
      const c = new AbortController(); const to = setTimeout(() => c.abort(), 14000);
      const r = await fetch(ep, { method: "POST", body: "data=" + encodeURIComponent(q), headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "wangmiaotw.com walk game (contact via site)" }, signal: c.signal });
      clearTimeout(to);
      if (!r.ok) continue;
      const t = await r.json();
      if (t && Array.isArray(t.elements)) { j = t; break; }
    } catch (_) {}
  }
  if (!j) return json({ error: "upstream" }, 502);
  const st = [], ways = [];
  for (const el of j.elements) {
    const tg = el.tags || {};
    if (el.type === "way" && tg.highway && Array.isArray(el.geometry)) {
      if (el.geometry.length > 1 && ways.length < 500) ways.push(el.geometry.flatMap(g => [+g.lat.toFixed(5), +g.lon.toFixed(5)]));
      continue;
    }
    const k = tg.leisure === "dog_park" ? "dog_park" : tg.leisure === "playground" ? "playground" : tg.leisure === "park" ? "park" : tg.amenity === "drinking_water" ? "water" : null;
    const la = el.lat != null ? el.lat : el.center && el.center.lat, lo = el.lon != null ? el.lon : el.center && el.center.lon;
    if (!k || la == null) continue;
    st.push([el.type[0] + el.id, k, +la.toFixed(6), +lo.toFixed(6), String(tg.name || "").slice(0, 20)]);
  }
  const body = JSON.stringify({ t: tile, st: st.slice(0, 60), w: ways });
  waitUntil(cache.put(key, new Response(body, { headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=604800" } })));
  return json(body, 200, { "Cache-Control": "public, max-age=86400", "X-Cache": "MISS" });
}

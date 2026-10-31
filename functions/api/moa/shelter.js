// 農業部「動物認領養」（收容所動物）開放資料轉接：給排程主機用（農業部只開放台灣網路）。
// GET /api/moa/shelter?area=2&kind=狗   快取 1 小時
export async function onRequestGet({ request, waitUntil }) {
  const u = new URL(request.url), area = u.searchParams.get("area") || "", kind = u.searchParams.get("kind") || "";
  const cors = { "Access-Control-Allow-Origin": "*", "Content-Type": "application/json; charset=utf-8" };
  if (!/^\d{1,2}$/.test(area) || !["狗", "貓"].includes(kind)) return new Response('{"error":"bad"}', { status: 400, headers: cors });
  const key = new Request(`https://wangmiaotw.com/api/moa/shelter/${area}/${encodeURIComponent(kind)}`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) return new Response(hit.body, { status: 200, headers: cors });
  let r;
  try { r = await fetch(`https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=QcbUEzN6E6DL&animal_kind=${encodeURIComponent(kind)}&animal_area_pkid=${area}`, { headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com)" } }); }
  catch (_) { return new Response('{"error":"upstream"}', { status: 502, headers: cors }); }
  const t = await r.text();
  if (!r.ok || !t.trim().startsWith("[")) return new Response('{"error":"upstream"}', { status: 502, headers: cors });
  const out = new Response(t, { status: 200, headers: { ...cors, "Cache-Control": "public, max-age=3600" } });
  waitUntil(cache.put(key, out.clone()));
  return out;
}

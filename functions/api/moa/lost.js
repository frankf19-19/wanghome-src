// 農業部「寵物遺失啟事」開放資料轉接：農業部只開放台灣網路，排程主機在國外，所以由這裡代抓。
// 快取 30 分鐘。GET /api/moa/lost
export async function onRequestGet({ waitUntil }) {
  const cors = { "Access-Control-Allow-Origin": "*", "Content-Type": "application/json; charset=utf-8" };
  const key = new Request("https://wangmiaotw.com/api/moa/lost");
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) return new Response(hit.body, { status: 200, headers: cors });
  let r;
  try {
    r = await fetch("https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=IFJomqVzyB0i", { headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com; service@wangmiaotw.com)" } });
  } catch (_) { return new Response('{"error":"upstream"}', { status: 502, headers: cors }); }
  const t = await r.text();
  if (!r.ok || !t.trim().startsWith("[")) return new Response('{"error":"upstream"}', { status: 502, headers: cors });
  const out = new Response(t, { status: 200, headers: { ...cors, "Cache-Control": "public, max-age=1800" } });
  waitUntil(cache.put(key, out.clone()));
  return out;
}

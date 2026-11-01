// 農業部「動物認領養」全台資料（領養頁選「全台」時用）：只留網頁用得到的欄位、只留開放認養的，快取 1 小時。
// GET /api/moa/adopt?kind=狗
const KEEP = ["animal_id", "animal_subid", "animal_area_pkid", "animal_shelter_pkid", "animal_kind", "animal_Variety", "animal_sex", "animal_bodytype",
  "animal_colour", "animal_age", "animal_sterilization", "animal_bacterin", "animal_foundplace", "animal_remark", "album_file", "animal_createtime",
  "animal_opendate", "shelter_name", "animal_place", "shelter_tel", "shelter_address", "animal_status"];
export async function onRequestGet({ request, waitUntil }) {
  const kind = new URL(request.url).searchParams.get("kind") || "";
  const cors = { "Access-Control-Allow-Origin": "*", "Content-Type": "application/json; charset=utf-8" };
  if (!["狗", "貓"].includes(kind)) return new Response('{"error":"bad"}', { status: 400, headers: cors });
  const key = new Request(`https://wangmiaotw.com/api/moa/adopt/v1/${encodeURIComponent(kind)}`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) return new Response(hit.body, { status: 200, headers: { ...cors, "Cache-Control": "public, max-age=1800" } });
  let r;
  try { r = await fetch(`https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=QcbUEzN6E6DL&animal_kind=${encodeURIComponent(kind)}`, { headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com)" } }); }
  catch (_) { return new Response('{"error":"upstream"}', { status: 502, headers: { ...cors, "Cache-Control": "no-store" } }); }
  let j;
  try { j = await r.json(); } catch (_) { j = null; }
  if (!r.ok || !Array.isArray(j)) return new Response('{"error":"upstream"}', { status: 502, headers: { ...cors, "Cache-Control": "no-store" } });
  const slim = j.filter((a) => a && a.animal_status === "OPEN").map((a) => { const o = {}; for (const k of KEEP) if (a[k] !== undefined && a[k] !== "") o[k] = a[k]; return o; });
  const out = new Response(JSON.stringify(slim), { status: 200, headers: { ...cors, "Cache-Control": "public, max-age=1800" } });
  waitUntil(cache.put(key, new Response(JSON.stringify(slim), { headers: { ...cors, "Cache-Control": "public, max-age=3600" } })));
  return out;
}

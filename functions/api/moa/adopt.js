// 農業部「動物認領養」全台資料（領養頁選「全台」時用）：只留網頁用得到的欄位、只留開放認養的，快取 1 小時（和 /adopt/ 靜態頁共用）。
// GET /api/moa/adopt?kind=狗
import { moaAdopt } from "../../../lib/adopt.js";
export async function onRequestGet({ request, waitUntil }) {
  const kind = new URL(request.url).searchParams.get("kind") || "";
  const cors = { "Access-Control-Allow-Origin": "*", "Content-Type": "application/json; charset=utf-8" };
  if (!["狗", "貓"].includes(kind)) return new Response('{"error":"bad"}', { status: 400, headers: cors });
  try { return new Response(JSON.stringify(await moaAdopt(kind, waitUntil)), { status: 200, headers: { ...cors, "Cache-Control": "public, max-age=1800" } }); }
  catch (_) { return new Response('{"error":"upstream"}', { status: 502, headers: { ...cors, "Cache-Control": "no-store" } }); }
}

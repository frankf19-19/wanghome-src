// IndexNow：新案件一登記就通知 Bing 等搜尋引擎來收錄（Google 不支援 IndexNow，靠 sitemap）。
// GET /api/indexnow?id=<案件 id>   網頁登記成功後背景呼叫；只有真的存在的公開案件才會送出。
// 金鑰檔放在網站根目錄 /<KEY>.txt（IndexNow 規定），由 build.sh 複製。
import { GUIDE_IDS } from "../../lib/guides.js";
import { CITIES } from "../../lib/seo.js";
const KEY = "73080c78bdeeab41a5d6fcb7fa0d1bc7";
const SITE = "https://wangmiaotw.com/";
const SUPABASE_URL = "https://nopyhfpaykkiieudvoko.supabase.co";
const ANON_KEY = "sb_publishable_WCeVQIAPH0UEEzhTwovqkg_lJ8Qjydb";
const ENDPOINTS = ["https://api.indexnow.org/indexnow", "https://www.bing.com/indexnow", "https://yandex.com/indexnow"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ALLOW = ["capacitor://localhost", "https://localhost", "https://wangmiaotw.com", "https://www.wangmiaotw.com"];

export async function onRequestGet({ request, waitUntil }) {
  const origin = request.headers.get("Origin") || "";
  const cors = { "Access-Control-Allow-Origin": ALLOW.includes(origin) ? origin : "https://wangmiaotw.com", "Vary": "Origin", "Content-Type": "application/json", "Cache-Control": "no-store" };
  const id = new URL(request.url).searchParams.get("id") || "";
  // ?all=1：把固定的重點頁（指南、各縣市走失、各縣市領養）一次送出；改版後手動呼叫一次即可
  if (new URL(request.url).searchParams.get("all") === "1") {
    const urlList = [SITE, `${SITE}l/`, `${SITE}g/`, `${SITE}app`, `${SITE}adopt/`, `${SITE}adopt/b/`, `${SITE}adopt/s/`, ...GUIDE_IDS().map((g) => `${SITE}g/${g}`),
      ...CITIES.map((c) => `${SITE}l/${encodeURIComponent(c)}`), ...CITIES.flatMap((c) => ["狗", "貓"].map((k) => `${SITE}adopt/${encodeURIComponent(c)}/${encodeURIComponent(k)}`))];
    // 共用入口常回 429（太多網站共用同一批 IP），所以依序改試 Bing、Yandex 自己的入口，有一個收下就算成功
    let status = 0, via = "";
    for (const ep of ENDPOINTS) {
      try { const r = await fetch(ep, { method: "POST", headers: { "Content-Type": "application/json; charset=utf-8" },
        body: JSON.stringify({ host: "wangmiaotw.com", key: KEY, keyLocation: `${SITE}${KEY}.txt`, urlList }) }); status = r.status; via = new URL(ep).host; } catch (_) {}
      if (status >= 200 && status < 300) break;
    }
    return new Response(JSON.stringify({ ok: status >= 200 && status < 300, status, via, urls: urlList.length }), { headers: cors });
  }
  if (!UUID.test(id)) return new Response('{"error":"bad_id"}', { status: 400, headers: cors });
  let row = null;
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/cases_public?id=eq.${id}&select=id,lost_city&limit=1`, { headers: { apikey: ANON_KEY, Accept: "application/json" } });
    if (r.ok) row = (await r.json())[0] || null;
  } catch (_) {}
  if (!row) return new Response('{"error":"not_found"}', { status: 404, headers: cors });
  const urlList = [`${SITE}p/${id}`, SITE, `${SITE}l/${encodeURIComponent(String(row.lost_city || "").replace(/^台/, "臺"))}`];
  const ping = (async () => { for (const ep of ENDPOINTS) { try { const r = await fetch(ep, { method: "POST", headers: { "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify({ host: "wangmiaotw.com", key: KEY, keyLocation: `${SITE}${KEY}.txt`, urlList }) }); if (r.status >= 200 && r.status < 300) return; } catch (_) {} } })();
  waitUntil(ping);
  return new Response(JSON.stringify({ ok: true, urls: urlList.length }), { headers: cors });
}

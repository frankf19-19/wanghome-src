// 收容所照片存檔（伺服器端）：只從農業部的網址抓照片，用服務金鑰存到 Supabase，避免任何人上傳假照片。
// 寵物登記網只接受台灣連線：由台灣使用者觸發時，Cloudflare 台北機房才連得到。
// POST /api/shelterstore  {"sub":"AAAIG1151029003","src":"https://www.pet.gov.tw/Upload/pic/xxx.jpg"}
// 需要在 Cloudflare Pages 設定環境變數 SB_SERVICE_KEY（加密）。
const SB = "https://nopyhfpaykkiieudvoko.supabase.co";
const auth = (key) => (key.startsWith("eyJ") ? { Authorization: `Bearer ${key}`, apikey: key } : { apikey: key });
const SRC_OK = /^https:\/\/(www\.pet\.gov\.tw|asms\.moa\.gov\.tw|asms\.coa\.gov\.tw)\/[^\s'"<>\\]+$/i;
const J = (o, st = 200) => new Response(JSON.stringify(o), { status: st, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
const isImg = (b) => { const u = new Uint8Array(b.slice(0, 12));
  return (u[0] === 0xFF && u[1] === 0xD8) || (u[0] === 0x89 && u[1] === 0x50) || (u[0] === 0x47 && u[1] === 0x49) || (u[8] === 0x57 && u[9] === 0x45); };
export async function onRequestPost({ request, env, params }) {
  const key = env.SB_SERVICE_KEY;
  if (!key) return J({ ok: false, why: "not configured" }, 503);
  let q; try { q = await request.json(); } catch (_) { return J({ ok: false }, 400); }
  const sub = String(q.sub || "").trim(), src0 = String(q.src || "");
  if (!/^[A-Za-z0-9-]{4,30}$/.test(sub)) return J({ ok: false }, 400);
  // 已經存過就不再抓
  const head = await fetch(`${SB}/storage/v1/object/public/photos/shelter/${sub}.jpg`, { method: "HEAD" });
  if (head.ok) return J({ ok: true, n: await setPhoto(key, sub), cached: true });
  // 照片來源：農業部網址，或用收容公告頁找照片（同一套邏輯在 /api/shelterpic）
  let src = SRC_OK.test(src0) ? src0 : "";
  const origin = new URL(request.url).origin;
  const target = src ? `${origin}/api/petimg?u=${encodeURIComponent(src)}` : `${origin}/api/shelterpic/${encodeURIComponent(sub)}.jpg`;
  let r; try { r = await fetch(target); } catch (_) { return J({ ok: false, why: "upstream" }, 502); }
  if (!r.ok) return J({ ok: false, why: "no photo" }, 404);
  const body = await r.arrayBuffer();
  if (body.byteLength < 800 || body.byteLength > 1500000 || !isImg(body)) return J({ ok: false, why: "bad image" }, 422);
  const ct = (r.headers.get("Content-Type") || "image/jpeg").split(";")[0];
  const up = await fetch(`${SB}/storage/v1/object/photos/shelter/${sub}.jpg`, { method: "POST", body,
    headers: { ...auth(key), "Content-Type": /^image\/(jpeg|png|webp)$/.test(ct) ? ct : "image/jpeg", "x-upsert": "false", "Cache-Control": "max-age=31536000" } });
  if (!up.ok && up.status !== 409) { const t = await up.text(); if (!/exists|Duplicate/i.test(t)) return J({ ok: false, why: "store" }, 502); }
  return J({ ok: true, n: await setPhoto(key, sub) });
}
async function setPhoto(key, sub) {
  try { const r = await fetch(`${SB}/rest/v1/rpc/set_match_photo`, { method: "POST", headers: { ...auth(key), "Content-Type": "application/json" }, body: JSON.stringify({ p_subid: sub }) });
    return r.ok ? await r.json() : 0; } catch (_) { return 0; }
}

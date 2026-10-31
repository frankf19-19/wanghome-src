// 寵物登記網的遺失照片轉接：加上跨網域標頭（協尋海報、分享圖卡要用），快取 7 天。
// GET /api/petpic/L1734342026102801.jpg   （沒有照片時回 404）
export async function onRequestGet({ params, waitUntil }) {
  const id = String(params.id || "").replace(/\.jpg$/, "");
  const cors = { "Access-Control-Allow-Origin": "*" };
  if (!/^[A-Za-z0-9]{6,40}$/.test(id)) return new Response("Not found", { status: 404, headers: cors });
  const key = new Request(`https://wangmiaotw.com/api/petpic/${id}.jpg`);
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) return new Response(hit.body, { status: hit.status, headers: hit.headers });
  let r;
  try {
    r = await fetch(`https://www.pet.gov.tw/XMLRequest/PET_PIC.ashx?File_No=${id}`, { headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com)" } });
  } catch (_) { return new Response("upstream", { status: 502, headers: cors }); }
  const ct = r.headers.get("Content-Type") || "";
  if (!r.ok || !/^image\/(jpeg|png|webp|gif)/i.test(ct)) {
    // 真的沒有照片才記住一天；對方伺服器暫時出錯時不要記，下次再試
    const real404 = r.status === 404 || (r.ok && !/^image\//.test(ct));
    const nf = new Response("Not found", { status: 404, headers: { ...cors, "Cache-Control": real404 ? "public, max-age=86400" : "no-store" } });
    if (real404) waitUntil(cache.put(key, nf.clone()));
    return nf;
  }
  const body = await r.arrayBuffer();
  if (body.byteLength < 500) return new Response("Not found", { status: 404, headers: cors });
  const out = new Response(body, { status: 200, headers: { ...cors, "Content-Type": "image/jpeg", "Cache-Control": "public, max-age=604800", "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'; sandbox" } });
  waitUntil(cache.put(key, out.clone()));
  return out;
}

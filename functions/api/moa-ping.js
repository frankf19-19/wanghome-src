// 暫時測試：Cloudflare 主機能不能讀到農業部開放資料（只開放台灣網路）
export async function onRequestGet({ request }) {
  const out = { colo: (request.cf && request.cf.colo) || "" };
  try {
    const r = await fetch("https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=IFJomqVzyB0i&$top=2", { headers: { "User-Agent": "WangMiaoHome/1.0 (https://wangmiaotw.com)" } });
    out.status = r.status; const t = await r.text(); out.len = t.length; out.head = t.slice(0, 80);
  } catch (e) { out.err = String(e); }
  return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } });
}

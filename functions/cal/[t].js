// 日曆訂閱網址改成本站網址（https://wangmiaotw.com/cal/<代碼>.ics），內容由 Supabase 的 pet-calendar 產生
const SB = "https://nopyhfpaykkiieudvoko.supabase.co/functions/v1/pet-calendar";
export async function onRequestGet({ params }) {
  const t = String(params.t || "").replace(/\.ics$/i, "");
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(t)) return new Response("Not found", { status: 404 });
  let r;
  try { r = await fetch(`${SB}?t=${encodeURIComponent(t)}`, { headers: { Accept: "text/calendar" } }); }
  catch (_) { return new Response("Temporarily unavailable", { status: 502 }); }
  return new Response(r.body, { status: r.status, headers: {
    "Content-Type": r.headers.get("Content-Type") || "text/calendar; charset=utf-8",
    "Cache-Control": "private, max-age=900",
    "X-Robots-Tag": "noindex" } });
}

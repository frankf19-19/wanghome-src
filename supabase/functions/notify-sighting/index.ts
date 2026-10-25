// 汪喵回家 — 目擊回報即時通知飼主（Email）v1.0
// 網址：POST https://<project>.supabase.co/functions/v1/notify-sighting  body: {"case_id":"<uuid>"}
// 網友送出目擊後由網頁呼叫。本函式只會寄「這個案件 30 分鐘內、還沒通知過」的目擊，
// 寄出後標記 notified，所以重複呼叫也不會重寄。需關閉 JWT 驗證（訪客也能回報）。
// 需要的 Secrets（Supabase → Edge Functions → Secrets）：GMAIL_USER、GMAIL_APP_PASSWORD
import { createClient } from "jsr:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const SITE = "https://frankf19-19.github.io/wanghome/";
const SITE_NAME = "汪喵回家";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

function serviceKey(): string {
  try {
    const j = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    const k = j.default ?? Object.values(j)[0];
    if (typeof k === "string" && k) return k;
  } catch (_) { /* ignore */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}
function fmt(ts: string) {
  const d = new Date(new Date(ts).getTime() + 8 * 3600e3);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getUTCMonth() + 1)}/${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let caseId = "";
  try { caseId = String((await req.json()).case_id ?? ""); } catch (_) { /* ignore */ }
  if (!/^[0-9a-f-]{36}$/.test(caseId)) return json({ error: "bad case_id" }, 400);

  const user = Deno.env.get("GMAIL_USER") ?? "", pass = (Deno.env.get("GMAIL_APP_PASSWORD") ?? "").replace(/\s/g, "");
  if (!user || !pass) return json({ sent: false, reason: "not_configured" });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });
  const { data: c, error: ce } = await sb.from("cases").select("id,name,contact_email,hidden").eq("id", caseId).maybeSingle();
  if (ce) return json({ error: "lookup" }, 500);
  if (!c || c.hidden || !c.contact_email) return json({ sent: false, reason: "no_email" });

  // 先「搶」下尚未通知的目擊（原子更新），避免同時兩次呼叫重複寄
  const since = new Date(Date.now() - 30 * 60e3).toISOString();
  const { data: ss, error: se } = await sb.from("sightings")
    .update({ notified: true })
    .eq("case_id", caseId).eq("notified", false).gte("created_at", since)
    .select("id,seen_at,place_text,direction,note,lat,lng,reporter_name,reporter_contact,photo_url");
  if (se) return json({ error: "claim" }, 500);
  if (!ss || !ss.length) return json({ sent: false, reason: "nothing_new" });

  const lines = [`你的毛孩「${c.name}」剛剛有 ${ss.length} 筆新的目擊回報：`, ""];
  for (const s of ss) {
    lines.push(`・${fmt(s.seen_at)}  ${s.place_text || "（見地圖）"}  ${s.direction ? "往" + s.direction : ""}`);
    if (s.note) lines.push(`  狀況：${s.note}`);
    if (s.lat) lines.push(`  地圖：https://www.google.com/maps?q=${s.lat},${s.lng}`);
    if (s.photo_url) lines.push(`  照片：${s.photo_url}`);
    lines.push(`  回報者：${s.reporter_name || "匿名"}${s.reporter_contact ? "，聯絡方式：" + s.reporter_contact : ""}`);
    lines.push("");
  }
  lines.push("確認後才會顯示在公開地圖上，請到管理頁處理（需要你的管理連結）：",
    `${SITE}#/manage/${caseId}`, "", "看到牠時請不要呼喊或追趕，慢慢靠近、蹲低、用食物引導。", "", `— ${SITE_NAME}`);

  const client = new SMTPClient({ connection: { hostname: "smtp.gmail.com", port: 465, tls: true, auth: { username: user, password: pass } } });
  try {
    await client.send({
      from: `${SITE_NAME} <${user}>`, to: c.contact_email,
      subject: `【${SITE_NAME}】有人看到${c.name}了！`, content: lines.join("\n"),
    });
    await client.close();
    return json({ sent: true, count: ss.length });
  } catch (e) {
    try { await client.close(); } catch (_) { /* ignore */ }
    // 寄失敗：還原成未通知，之後的每日排程或下次呼叫會再寄
    await sb.from("sightings").update({ notified: false }).in("id", ss.map((s) => s.id));
    console.error("send failed", String(e));
    return json({ sent: false, reason: "send_failed" }, 502);
  }
});

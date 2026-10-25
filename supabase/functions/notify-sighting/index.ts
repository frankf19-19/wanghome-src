// 汪喵回家 — 飼主 Email 通知 v1.3（用 Resend 從 noreply@wangmiaotw.com 寄出）
// 網址：POST https://<project>.supabase.co/functions/v1/notify-sighting
//   1. {"case_id":"<uuid>"}                                   網友送出目擊後由網頁呼叫：寄目擊通知給飼主
//   2. {"case_id":"<uuid>","action":"verify","token":"<管理代碼>"}  寄「確認信箱」信給飼主（登記後、改 Email 後、按重寄）
// 安全：飼主的 Email 必須先點確認信才會收到通知（避免有人拿別人的信箱登記來灌信）。
//       確認信內容固定、不含任何網友填的文字；同一案件 10 分鐘最多 1 封、同一信箱一天最多 5 封、全站每小時最多 150 封。
// 需關閉 JWT 驗證（訪客也能回報）。
// Secrets（Supabase → Edge Functions → Secrets）：RESEND_API_KEY（建議）；或舊方式 GMAIL_USER、GMAIL_APP_PASSWORD
import { createClient } from "jsr:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const SITE = "https://wangmiaotw.com/";
const SITE_NAME = "汪喵回家";
const MAIL_FROM = "noreply@wangmiaotw.com", REPLY_TO = "service@wangmiaotw.com";
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
const escH = (s: string) => s.replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]!));
async function sha256hex(s: string) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

const resendKey = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const gUser = Deno.env.get("GMAIL_USER") ?? "", gPass = (Deno.env.get("GMAIL_APP_PASSWORD") ?? "").replace(/\s/g, "");
async function sendMail(to: string, subject: string, text: string, html?: string) {
  if (resendKey) {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: `${SITE_NAME} <${MAIL_FROM}>`, to: [to], reply_to: REPLY_TO, subject, text, ...(html ? { html } : {}) }),
    });
    if (!r.ok) throw new Error(`resend ${r.status} ${(await r.text()).slice(0, 200)}`);
    return;
  }
  const client = new SMTPClient({ connection: { hostname: "smtp.gmail.com", port: 465, tls: true, auth: { username: gUser, password: gPass } } });
  try { await client.send({ from: `${SITE_NAME} <${gUser}>`, to, subject, content: text, ...(html ? { html } : {}) }); }
  finally { try { await client.close(); } catch (_) { /* ignore */ } }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch (_) { /* ignore */ }
  const caseId = String(body.case_id ?? "");
  if (!/^[0-9a-f-]{36}$/.test(caseId)) return json({ error: "bad case_id" }, 400);
  if (!resendKey && (!gUser || !gPass)) return json({ sent: false, reason: "not_configured" });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });
  const { data: c, error: ce } = await sb.from("cases")
    .select("id,name,contact_email,hidden,email_verified,email_verify_sent_at").eq("id", caseId).maybeSingle();
  if (ce) return json({ error: "lookup" }, 500);
  if (!c || c.hidden || !c.contact_email) return json({ sent: false, reason: "no_email" });
  const to = String(c.contact_email).trim().toLowerCase();

  const hourAgo = new Date(Date.now() - 3600e3).toISOString();
  const count = async (q: (x: any) => any) => {
    const { count } = await q(sb.from("case_mail_log").select("case_id", { count: "exact", head: true }));
    return count ?? 0;
  };
  // 全站每小時最多 150 封
  if (await count((x) => x.gte("sent_at", hourAgo)) >= 150) return json({ sent: false, reason: "throttled" });

  // ---------------------------------------------------------------- 確認信箱
  if (body.action === "verify") {
    const token = String(body.token ?? "");
    let { data: ok } = await sb.rpc("can_manage_case", { p_id: caseId, p_token: token });
    if (!ok) {   // 已登入的飼主（沒有管理代碼）：用登入身分確認
      const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
      if (jwt && jwt.split(".").length === 3) {
        const { data: u } = await sb.auth.getUser(jwt);
        if (u?.user) {
          const { data: own } = await sb.from("cases").select("id").eq("id", caseId).eq("owner_id", u.user.id).maybeSingle();
          ok = !!own;
        }
      }
    }
    if (!ok) return json({ sent: false, reason: "bad_token" }, 403);
    if (c.email_verified) return json({ sent: false, reason: "already_verified" });
    if (c.email_verify_sent_at && Date.now() - new Date(c.email_verify_sent_at).getTime() < 10 * 60e3)
      return json({ sent: false, reason: "too_soon" });
    const dayAgo = new Date(Date.now() - 24 * 3600e3).toISOString();
    if (await count((x) => x.eq("to_email", to).gte("sent_at", dayAgo)) >= 5) return json({ sent: false, reason: "throttled" });

    const key = [...crypto.getRandomValues(new Uint8Array(24))].map((x) => x.toString(16).padStart(2, "0")).join("");
    const { error: ue } = await sb.from("cases")
      .update({ email_verify_hash: await sha256hex(key), email_verify_sent_at: new Date().toISOString() }).eq("id", caseId);
    if (ue) return json({ error: "save" }, 500);
    const link = `${SITE}#/verify-email?c=${caseId}&k=${key}`;
    const name = String(c.name ?? "").slice(0, 30);
    const text = [`你好，你在${SITE_NAME}登記了走失協尋「${name}」，並留下這個 Email。`, "",
      "請點下面的連結確認這是你的信箱。確認之後，有人回報看到牠，我們會馬上寄信通知你：", link, "",
      "連結 7 天內有效。", "不是你登記的？直接刪除這封信就好，我們不會再寄信給你。", "", `— ${SITE_NAME}　${SITE}`].join("\n");
    const html = `<!DOCTYPE html><html lang="zh-Hant"><body style="margin:0;background:#EFF2EE;font-family:'PingFang TC','Microsoft JhengHei',sans-serif;color:#141E22">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#fff;border-radius:16px;overflow:hidden">
<tr><td style="background:#CC3F1E;padding:18px 24px;color:#fff;font-size:22px;font-weight:900">🐾 ${SITE_NAME}</td></tr>
<tr><td style="padding:26px 24px 8px">
<p style="margin:0 0 12px;font-size:22px;font-weight:900">請確認你的信箱</p>
<p style="margin:0 0 22px;font-size:17px;line-height:1.7;color:#36454B">你在${SITE_NAME}登記了走失協尋「${escH(name)}」。點下面的按鈕確認這是你的信箱，之後有人回報看到牠，我們會馬上寄信通知你。</p>
<a href="${link}" style="display:block;background:#CC3F1E;color:#fff;text-decoration:none;font-size:20px;font-weight:900;padding:16px 20px;border-radius:12px;text-align:center">✅ 確認信箱</a>
<p style="margin:18px 0 0;font-size:15px;line-height:1.7;color:#36454B">連結 7 天內有效。</p></td></tr>
<tr><td style="padding:18px 24px 24px"><p style="margin:0;font-size:13px;line-height:1.7;color:#5A6A70;border-top:1px solid #E3E7E2;padding-top:14px">
不是你登記的？直接刪除這封信就好，我們不會再寄信給你。<br>${SITE_NAME}｜全台走失毛孩協尋平台　<a href="${SITE}" style="color:#CC3F1E">wangmiaotw.com</a></p></td></tr>
</table></td></tr></table></body></html>`;
    try {
      await sendMail(to, `【${SITE_NAME}】請確認你的信箱，才收得到「${name}」的目擊通知`, text, html);
      await sb.from("case_mail_log").insert({ case_id: caseId, to_email: to });
      return json({ sent: true });
    } catch (e) {
      await sb.from("cases").update({ email_verify_sent_at: null }).eq("id", caseId);
      console.error("verify send failed", String(e));
      return json({ sent: false, reason: "send_failed" }, 502);
    }
  }

  // ---------------------------------------------------------------- 目擊通知
  if (!c.email_verified) return json({ sent: false, reason: "unverified" });
  // 同一案件、同一信箱一小時最多 6 封；超過就先不寄，目擊留著下次一起寄
  if (await count((x) => x.eq("case_id", caseId).gte("sent_at", hourAgo)) >= 6) return json({ sent: false, reason: "throttled" });
  if (await count((x) => x.eq("to_email", to).gte("sent_at", hourAgo)) >= 6) return json({ sent: false, reason: "throttled" });

  // 先「搶」下尚未通知的目擊（原子更新），避免同時兩次呼叫重複寄
  const since = new Date(Date.now() - 6 * 3600e3).toISOString();   // 被限流延後的目擊，6 小時內都會補寄
  const { data: ss, error: se } = await sb.from("sightings")
    .update({ notified: true })
    .eq("case_id", caseId).eq("notified", false).neq("status", "rejected").gte("created_at", since)
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
  lines.push("以上是網友填寫的內容，請自行判斷真假；本站不會要你匯款或提供密碼。",
    "確認後才會顯示在公開地圖上，請到管理頁處理（需要你的管理網址）：",
    `${SITE}#/manage/${caseId}`, "", "看到牠時請不要呼喊或追趕，慢慢靠近、蹲低、用食物引導。", "", `— ${SITE_NAME}`);

  try {
    await sendMail(to, `【${SITE_NAME}】有人看到${c.name}了！`, lines.join("\n"));
    await sb.from("case_mail_log").insert({ case_id: caseId, to_email: to });
    return json({ sent: true, count: ss.length });
  } catch (e) {
    // 寄失敗：還原成未通知，之後的每日排程或下次呼叫會再寄
    await sb.from("sightings").update({ notified: false }).in("id", ss.map((s: { id: string }) => s.id));
    console.error("send failed", String(e));
    return json({ sent: false, reason: "send_failed" }, 502);
  }
});

// 汪喵回家 — 私訊推播 v1.0
// 網址：POST https://<project>.supabase.co/functions/v1/notify-message   {"chat_id":"<uuid>"}
// 會員送出訊息後由網頁／App 呼叫（帶登入權杖）：推播給對話裡的另一個人。
// 安全：只推「呼叫者自己剛送出（2 分鐘內）」的訊息；對方已讀就不推；同一對話 20 秒內只推一次（連續傳很多則不會一直響）。
// Secrets：APNS_P8、APNS_KEY_ID、APNS_TEAM_ID（和 notify-sighting 共用）。可開啟 JWT 驗證。
import { createClient } from "jsr:@supabase/supabase-js@2";

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
// ===== 手機推播（iPhone／APNs）=====
// 需要的 Secrets：APNS_P8（Apple 推播金鑰 .p8 的內容）、APNS_KEY_ID、APNS_TEAM_ID；沒設定就不推
const APNS_P8 = (Deno.env.get("APNS_P8") ?? "").trim();
const APNS_KEY_ID = (Deno.env.get("APNS_KEY_ID") ?? "").trim();
const APNS_TEAM_ID = (Deno.env.get("APNS_TEAM_ID") ?? "").trim();
const APNS_TOPIC = (Deno.env.get("APNS_TOPIC") ?? "com.wangmiaotw.app").trim();
let apnsJwt = { t: 0, v: "" };
const b64u = (b: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
async function apnsAuth(): Promise<string> {
  if (apnsJwt.v && Date.now() - apnsJwt.t < 40 * 60e3) return apnsJwt.v;
  const der = Uint8Array.from(atob(APNS_P8.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = (o: unknown) => b64u(new TextEncoder().encode(JSON.stringify(o)));
  const data = enc({ alg: "ES256", kid: APNS_KEY_ID }) + "." + enc({ iss: APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) });
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(data));
  apnsJwt = { t: Date.now(), v: data + "." + b64u(sig) };
  return apnsJwt.v;
}
// 推給某位會員的所有 iPhone；回傳成功幾支
async function pushToUser(userId: string, title: string, body: string, url = "#/inbox"): Promise<number> {
  if (!APNS_P8 || !APNS_KEY_ID || !APNS_TEAM_ID || !userId) return 0;
  const base = Deno.env.get("SUPABASE_URL")!, key = serviceKey();
  const h = { apikey: key, ...(key.startsWith("eyJ") ? { Authorization: `Bearer ${key}` } : {}) };
  let toks: { token: string; platform: string }[] = [];
  try { const r = await fetch(`${base}/rest/v1/push_tokens?select=token,platform&user_id=eq.${userId}`, { headers: h }); if (r.ok) toks = await r.json(); } catch (_) { return 0; }
  let n = 0;
  for (const t of toks.filter((x) => x.platform === "ios")) {
    try {
      const r = await fetch(`https://api.push.apple.com/3/device/${t.token}`, { method: "POST",
        headers: { authorization: `bearer ${await apnsAuth()}`, "apns-topic": APNS_TOPIC, "apns-push-type": "alert", "apns-priority": "10", "content-type": "application/json" },
        body: JSON.stringify({ aps: { alert: { title, body }, sound: "default" }, url }) });
      if (r.ok) n++;
      else if (r.status === 410 || r.status === 400) {   // 手機已經刪掉 App 或代碼失效：不再推
        const why = await r.text().catch(() => "");
        if (r.status === 410 || /Unregistered/.test(why))
          await fetch(`${base}/rest/v1/push_tokens?token=eq.${encodeURIComponent(t.token)}`, { method: "DELETE", headers: h }).catch(() => {});
        else console.error("APNs", r.status, why.slice(0, 200));
      }
    } catch (_) { /* 推播失敗不影響寄信 */ }
  }
  return n;
}


Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let body: any = {};
  try { body = await req.json(); } catch (_) { return json({ error: "json" }, 400); }
  const chatId = String(body.chat_id ?? "");
  if (!/^[0-9a-f-]{36}$/.test(chatId)) return json({ error: "bad id" }, 400);
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });
  const { data: u } = await sb.auth.getUser(jwt).catch(() => ({ data: null as any }));
  const me = u?.user?.id;
  if (!me) return json({ error: "login" }, 401);
  const since = new Date(Date.now() - 120e3).toISOString();
  const { data: msg } = await sb.from("chat_messages").select("id,kind,body,created_at")
    .eq("chat_id", chatId).eq("sender_id", me).gte("created_at", since).order("id", { ascending: false }).limit(1).maybeSingle();
  if (!msg) return json({ sent: 0, reason: "no message" });
  const [{ data: others }, { data: prof }, { data: chat }] = await Promise.all([
    sb.from("chat_members").select("user_id,last_read_at,pushed_at").eq("chat_id", chatId).neq("user_id", me),
    sb.from("profiles").select("username").eq("id", me).maybeSingle(),
    sb.from("chats").select("kind,case_id").eq("id", chatId).maybeSingle(),
  ]);
  const name = prof?.username || "會員";
  let ctx = "";
  if (chat?.kind === "case" && chat.case_id) {
    const { data: c } = await sb.from("cases").select("name").eq("id", chat.case_id).maybeSingle();
    if (c?.name) ctx = `（${c.name}）`;
  }
  const text = msg.kind === "photo" ? "傳了一張照片" : msg.kind === "ask" ? "請你證明是飼主" : String(msg.body ?? "").slice(0, 120);
  let sent = 0;
  for (const o of others ?? []) {
    if (o.last_read_at && new Date(o.last_read_at) >= new Date(msg.created_at)) continue;   // 已經讀了
    if (o.pushed_at && Date.now() - new Date(o.pushed_at).getTime() < 20e3) continue;         // 剛推過
    const { data: blk } = await sb.from("user_blocks").select("blocker").eq("blocker", o.user_id).eq("blocked", me).maybeSingle();
    if (blk) continue;
    await sb.from("chat_members").update({ pushed_at: new Date().toISOString() }).eq("chat_id", chatId).eq("user_id", o.user_id);
    sent += await pushToUser(o.user_id, `${name}${ctx}`, text, `#/chat/${chatId}`);
  }
  return json({ sent });
});

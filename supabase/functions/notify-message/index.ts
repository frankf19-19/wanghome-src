// 汪喵回家 — 私訊推播 v1.1（加上民眾送養）
// 網址：POST https://<project>.supabase.co/functions/v1/notify-message   {"chat_id":"<uuid>"} 或 {"friend":"<對方 uuid>"}（好友邀請／接受）
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
// ===== 手機推播（Android／Firebase FCM）=====
// 需要的 Secret：FCM_SERVICE_ACCOUNT（Firebase 服務帳戶金鑰 JSON 的內容）；沒設定就不推 Android
let fcmSa: { project_id: string; client_email: string; private_key: string } | null = null;
try { const raw = (Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "").trim(); if (raw) { const j = JSON.parse(raw); if (j.project_id && j.client_email && j.private_key) fcmSa = j; } } catch (_) { fcmSa = null; }
let fcmTok = { t: 0, v: "" };
async function fcmAuth(): Promise<string> {
  if (fcmTok.v && Date.now() - fcmTok.t < 45 * 60e3) return fcmTok.v;
  const sa = fcmSa!;
  const der = Uint8Array.from(atob(sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const u = (b: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const enc = (o: unknown) => u(new TextEncoder().encode(JSON.stringify(o)));
  const now = Math.floor(Date.now() / 1000);
  const data = enc({ alg: "RS256", typ: "JWT" }) + "." + enc({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 });
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(data));
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=" + encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer") + "&assertion=" + data + "." + u(sig) });
  const j = await r.json();
  if (!r.ok || !j.access_token) throw new Error("fcm auth " + r.status);
  fcmTok = { t: Date.now(), v: j.access_token };
  return fcmTok.v;
}
// 推給某位會員的所有 iPhone；回傳成功幾支
async function pushToUser(userId: string, title: string, body: string, url = "#/inbox"): Promise<number> {
  const apnsOK = !!(APNS_P8 && APNS_KEY_ID && APNS_TEAM_ID);
  if (!userId || (!apnsOK && !fcmSa)) return 0;
  const base = Deno.env.get("SUPABASE_URL")!, key = serviceKey();
  const h = { apikey: key, ...(key.startsWith("eyJ") ? { Authorization: `Bearer ${key}` } : {}) };
  let toks: { token: string; platform: string }[] = [];
  try { const r = await fetch(`${base}/rest/v1/push_tokens?select=token,platform&user_id=eq.${userId}`, { headers: h }); if (r.ok) toks = await r.json(); } catch (_) { return 0; }
  let n = 0;
  if (apnsOK) for (const t of toks.filter((x) => x.platform === "ios")) {
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
  if (fcmSa) for (const t of toks.filter((x) => x.platform === "android")) {
    try {
      const r = await fetch(`https://fcm.googleapis.com/v1/projects/${fcmSa.project_id}/messages:send`, { method: "POST",
        headers: { authorization: `Bearer ${await fcmAuth()}`, "content-type": "application/json" },
        body: JSON.stringify({ message: { token: t.token, notification: { title, body }, data: { url }, android: { priority: "HIGH", notification: { sound: "default" } } } }) });
      if (r.ok) n++;
      else {
        const why = await r.text().catch(() => "");
        if (r.status === 404 || /UNREGISTERED/.test(why))   // 手機已經刪掉 App 或代碼失效：不再推
          await fetch(`${base}/rest/v1/push_tokens?token=eq.${encodeURIComponent(t.token)}`, { method: "DELETE", headers: h }).catch(() => {});
        else console.error("FCM", r.status, why.slice(0, 200));
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
  const friendId = String(body.friend ?? "");
  const rhApp = String(body.rehome_app ?? "");
  if (!/^[0-9a-f-]{36}$/.test(chatId) && !/^[0-9a-f-]{36}$/.test(friendId) && !/^[0-9a-f-]{36}$/.test(rhApp)) return json({ error: "bad id" }, 400);
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });
  const { data: u } = await sb.auth.getUser(jwt).catch(() => ({ data: null as any }));
  const me = u?.user?.id;
  if (!me) return json({ error: "login" }, 401);
  // 民眾送養：新申請、送養人回覆、切結書、近況回報。只推「呼叫者自己剛做的」（2 分鐘內），同一件事只推一次
  if (rhApp) {
    const { data: a } = await sb.from("rehome_apps").select("id,rehome_id,applicant_id,status,contact_name,created_at,updated_at,owner_agree_at,applicant_agree_at,pushed").eq("id", rhApp).maybeSingle();
    if (!a) return json({ sent: 0, reason: "none" });
    const { data: r } = await sb.from("rehomes").select("owner_id,name,contact_name").eq("id", a.rehome_id).maybeSingle();
    if (!r) return json({ sent: 0, reason: "none" });
    const fresh = (t: string | null) => !!t && Date.now() - new Date(t).getTime() < 120e3;
    const P: Record<string, string> = a.pushed || {};
    const url = `#/rehome/app/${a.id}`;
    let to = "", title = "", text = "", key = "", val = "";
    if (me === a.applicant_id) {
      const { data: u } = await sb.from("rehome_updates").select("id,note,photo,created_at").eq("app_id", a.id).order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (a.status === "pending" && fresh(a.created_at) && P.apply !== a.created_at) {
        const { data: prof } = await sb.from("profiles").select("username").eq("id", me).maybeSingle();
        to = r.owner_id; title = "新的領養申請"; text = `${prof?.username || a.contact_name} 想領養${r.name}，去看看問卷`; key = "apply"; val = a.created_at;
      } else if (a.status === "meet" && fresh(a.applicant_agree_at) && P.aa !== a.applicant_agree_at) {
        to = r.owner_id; title = `${r.name}的認養切結書`; text = `${a.contact_name}同意了切結書`; key = "aa"; val = a.applicant_agree_at;
      } else if (a.status === "adopted" && u && fresh(u.created_at) && P.u !== u.id) {
        to = r.owner_id; title = `${r.name}的近況`; text = u.note ? String(u.note).slice(0, 100) : `${a.contact_name}傳了${r.name}的新照片`; key = "u"; val = u.id;
      }
    } else if (me === r.owner_id) {
      const ST: Record<string, string> = { talking: `送養人想跟你聊聊${r.name}，可以傳訊息了`, meet: `送養人同意跟你見面了（${r.name}）`, declined: `送養人這次沒有選擇你（${r.name}），謝謝你願意給毛孩一個家`, adopted: `${r.name}正式成為你的家人了 🎉` };
      if (a.status === "meet" && fresh(a.owner_agree_at) && P.ao !== a.owner_agree_at && P.st === "meet") {
        to = a.applicant_id; title = `${r.name}的認養切結書`; text = `送養人${r.contact_name}同意了切結書，換你看看`; key = "ao"; val = a.owner_agree_at;
      } else if (ST[a.status] && fresh(a.updated_at) && P.st !== a.status) {
        to = a.applicant_id; title = "民眾送養"; text = ST[a.status]; key = "st"; val = a.status;
      }
    }
    if (!to) return json({ sent: 0, reason: "old" });
    await sb.from("rehome_apps").update({ pushed: { ...P, [key]: val } }).eq("id", a.id);
    return json({ sent: await pushToUser(to, title, text, url) });
  }
  // 好友邀請／接受邀請：只推「呼叫者自己剛做的」（2 分鐘內），每一筆只推一次
  if (friendId) {
    if (friendId === me) return json({ sent: 0 });
    const a = me < friendId ? me : friendId, b = me < friendId ? friendId : me;
    const { data: f } = await sb.from("friends").select("requester,status,created_at,accepted_at,pushed_at").eq("a", a).eq("b", b).maybeSingle();
    if (!f || f.pushed_at) return json({ sent: 0, reason: "none" });
    const fresh = (t: string | null) => !!t && Date.now() - new Date(t).getTime() < 120e3;
    let title = "", text = "";
    const { data: prof } = await sb.from("profiles").select("username").eq("id", me).maybeSingle();
    const name = prof?.username || "會員";
    if (f.status === "pending" && f.requester === me && fresh(f.created_at)) { title = "好友邀請"; text = `${name} 想加你為好友`; }
    else if (f.status === "accepted" && fresh(f.accepted_at)) { title = "成為好友了"; text = `${name} 和你成為好友了，可以直接聊天`; }
    else return json({ sent: 0, reason: "old" });
    await sb.from("friends").update({ pushed_at: new Date().toISOString() }).eq("a", a).eq("b", b);
    return json({ sent: await pushToUser(friendId, title, text, "#/chats?tab=friends") });
  }
  const since = new Date(Date.now() - 120e3).toISOString();
  const { data: msg } = await sb.from("chat_messages").select("id,kind,body,created_at")
    .eq("chat_id", chatId).eq("sender_id", me).gte("created_at", since).order("id", { ascending: false }).limit(1).maybeSingle();
  if (!msg) return json({ sent: 0, reason: "no message" });
  const [{ data: others }, { data: prof }, { data: chat }] = await Promise.all([
    sb.from("chat_members").select("user_id,last_read_at,pushed_at,muted").eq("chat_id", chatId).neq("user_id", me),
    sb.from("profiles").select("username").eq("id", me).maybeSingle(),
    sb.from("chats").select("kind,case_id").eq("id", chatId).maybeSingle(),
  ]);
  const name = prof?.username || "會員";
  let ctx = "";
  if (chat?.kind === "rehome") {
    const { data: ch2 } = await sb.from("chats").select("rehome_app_id").eq("id", chatId).maybeSingle();
    const { data: ra } = ch2?.rehome_app_id ? await sb.from("rehome_apps").select("rehome_id").eq("id", ch2.rehome_app_id).maybeSingle() : { data: null };
    const { data: rr } = ra ? await sb.from("rehomes").select("name").eq("id", ra.rehome_id).maybeSingle() : { data: null };
    if (rr?.name) ctx = `（送養・${rr.name}）`;
  }
  if (chat?.kind === "case" && chat.case_id) {
    const { data: c } = await sb.from("cases").select("name").eq("id", chat.case_id).maybeSingle();
    if (c?.name) ctx = `（${c.name}）`;
  }
  const text = msg.kind === "photo" ? "傳了照片" : msg.kind === "voice" ? "傳了一段語音" : msg.kind === "sticker" || /^\[stk:[a-z0-9_]+\]$/.test(String(msg.body ?? "")) ? "傳了一張貼圖" : /^\[loc:/.test(String(msg.body ?? "")) ? "傳了一個位置給你" : msg.kind === "ask" ? "請你證明是飼主" : String(msg.body ?? "").slice(0, 120);
  let sent = 0;
  for (const o of others ?? []) {
    if ((o as any).muted) continue;                                                       // 對方把這個對話靜音了
    if (o.last_read_at && new Date(o.last_read_at) >= new Date(msg.created_at)) continue;   // 已經讀了
    if (o.pushed_at && Date.now() - new Date(o.pushed_at).getTime() < 20e3) continue;         // 剛推過
    if (o.pushed_at && new Date(o.pushed_at) >= new Date(msg.created_at)) continue;          // 這則已經推過了
    const { data: blk } = await sb.from("user_blocks").select("blocker").eq("blocker", o.user_id).eq("blocked", me).maybeSingle();
    if (blk) continue;
    await sb.from("chat_members").update({ pushed_at: new Date().toISOString() }).eq("chat_id", chatId).eq("user_id", o.user_id);
    sent += await pushToUser(o.user_id, `${name}${ctx}`, text, `#/chat/${chatId}`);
  }
  return json({ sent });
});

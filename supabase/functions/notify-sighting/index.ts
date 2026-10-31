// 汪喵回家 — 飼主 Email 通知 v1.9（用 Resend 從 noreply@wangmiaotw.com 寄出）
// 網址：POST https://<project>.supabase.co/functions/v1/notify-sighting
//   1. {"case_id":"<uuid>"}                                   網友送出目擊後由網頁呼叫：寄目擊通知給飼主
//   2. {"case_id":"<uuid>","action":"verify","token":"<管理代碼>"}  寄「確認信箱」信給飼主（登記後、改 Email 後、按重寄）
// 安全：飼主的 Email 必須先點確認信才會收到通知（避免有人拿別人的信箱登記來灌信）。
//       確認信內容固定、不含任何網友填的文字；同一案件 10 分鐘最多 1 封、一天最多 3 封；同一信箱一天最多 3 封；確認信全站每小時 30 封，目擊通知另計 150 封。
//       v1.6：每個網路位址每小時有上限；每日寄信額度分類（確認信 ≤15、目擊 ≤45）；只有「協尋中」的案件才寄目擊通知；同一案件一天最多 20 封。
//       v1.7：每個網路位址另有每天上限（目擊通知 15、確認信 6）；IPv6 位址分組修正。
//       v1.8：目擊通知改成有版面的信：照片直接顯示、地圖與管理頁用大按鈕。
//       v1.9：信裡的管理按鈕附 30 天有效的信件專用鑰匙，點了直接進管理頁。
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

// IPv6 取前 64 位元當一組（同一個家用網路的裝置算同一個人）；正確處理 "::" 縮寫
function v6net64(ip: string): string {
  const a = ip.split("%")[0].toLowerCase();
  const [l, r] = a.includes("::") ? a.split("::") : [a, null];
  const L = l ? l.split(":") : [], R = r ? r.split(":") : [];
  const full = r === null ? L : [...L, ...Array(Math.max(0, 8 - L.length - R.length)).fill("0"), ...R];
  return full.slice(0, 4).map((x) => (parseInt(x || "0", 16) || 0).toString(16)).join(":") + "::/64";
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
  // 每個網路位址每小時的呼叫上限（確認信 10 次、目擊通知 30 次）
  // 只信任 Cloudflare 給的位址（x-forwarded-for 可以被偽造）；IPv6 以 /64 為一組
  let ip = (req.headers.get("cf-connecting-ip") ?? "unknown").trim();
  if (ip.includes(":")) ip = v6net64(ip);
  const isVerify = body.action === "verify";
  {
    // 每小時上限，加上每天上限（避免同一個人慢慢把全站一天的寄信額度用光）
    const lim: [string, number, string][] = isVerify
      ? [["edge_verify", 10, "1 hour"], ["edge_verify_d", 6, "1 day"]]
      : [["edge_notify", 30, "1 hour"], ["edge_notify_d", 15, "1 day"]];
    for (const [k, n, w] of lim) {
      const { data: rok, error: re } = await sb.rpc("edge_rate_ok", { p_kind: k, p_ip: ip, p_max: n, p_window: w });
      if (re || rok !== true) return json({ sent: false, reason: "throttled" }, 429);
    }
  }
  const { data: c, error: ce } = await sb.from("cases")
    .select("id,name,status,contact_email,hidden,email_verified,email_verify_sent_at,email_verify_hash,owner_id").eq("id", caseId).maybeSingle();
  if (ce) return json({ error: "lookup" }, 500);
  // 會員登記的案件：手機推播給飼主（不需要確認信箱）
  // 只有 15 分鐘內真的有新目擊才推；同一案件 10 分鐘最多推一次（避免被人拿來洗推播）
  if (!isVerify && c && !c.hidden && c.owner_id && c.status === "searching") {
    try {
      const { count: fresh } = await sb.from("sightings").select("id", { count: "exact", head: true })
        .eq("case_id", caseId).neq("status", "rejected").gte("created_at", new Date(Date.now() - 15 * 60e3).toISOString());
      const { count: recent } = await sb.from("case_mail_log").select("case_id", { count: "exact", head: true })
        .eq("case_id", caseId).eq("kind", "push").gte("sent_at", new Date(Date.now() - 10 * 60e3).toISOString());
      if ((fresh ?? 0) > 0 && (recent ?? 0) === 0) {
        await sb.from("case_mail_log").insert({ case_id: caseId, to_email: "push", kind: "push" });
        await pushToUser(c.owner_id, `有人看到${c.name}了！`, "點開看目擊的時間和位置，確認是不是牠", `#/manage/${caseId}`);
      }
    } catch (_) { /* 推播失敗不影響寄信 */ }
  }
  if (!c || c.hidden || !c.contact_email) return json({ sent: false, reason: "no_email" });
  const to = String(c.contact_email).trim().toLowerCase();

  const hourAgo = new Date(Date.now() - 3600e3).toISOString();
  const count = async (q: (x: any) => any) => {
    const { count } = await q(sb.from("case_mail_log").select("case_id", { count: "exact", head: true }));
    return count ?? 0;
  };
  // 同一個人的信箱（Gmail 的 . 和 +標籤 視為同一個）
  const norm = (e: string) => { const [u, d] = e.split("@"); if (!d) return e;
    const dom = d === "googlemail.com" ? "gmail.com" : d; let user = u.split("+")[0];
    if (dom === "gmail.com") user = user.replace(/\./g, ""); return `${user}@${dom}`; };
  const toKey = norm(to);
  // 每日寄信預算（和排程共用）：網站通知一天最多 60 封，其中確認信最多 15、目擊通知最多 45
  const budget = async (kind: "verify" | "notify") => {
    const { data, error } = await sb.rpc("mail_budget_take", { p_kind: kind, p_cap: 60, p_kind_cap: kind === "verify" ? 15 : 45 });
    return !error && data === true;
  };
  const budgetBack = (kind: string) => sb.rpc("mail_budget_return", { p_kind: kind }).then(() => {}, () => {});

  // ---------------------------------------------------------------- 確認信箱
  if (isVerify) {
    // 確認信另外計上限（全站每小時 30 封），不會佔掉目擊通知的額度
    if (await count((x) => x.eq("kind", "verify").gte("sent_at", hourAgo)) >= 30) return json({ sent: false, reason: "throttled" });
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
    const dayAgo = new Date(Date.now() - 24 * 3600e3).toISOString();
    // 同一案件每天最多 3 封確認信；同一信箱每天最多 3 封
    if (await count((x) => x.eq("case_id", caseId).eq("kind", "verify").gte("sent_at", dayAgo)) >= 3) return json({ sent: false, reason: "throttled" });
    if (await count((x) => x.eq("to_email", toKey).gte("sent_at", dayAgo)) >= 3) return json({ sent: false, reason: "throttled" });

    // 先「佔位」再寄：同時送來的請求只有一個會成功（10 分鐘內不重寄）
    const key = [...crypto.getRandomValues(new Uint8Array(24))].map((x) => x.toString(16).padStart(2, "0")).join("");
    const tenAgo = new Date(Date.now() - 10 * 60e3).toISOString();
    const { data: claimed, error: ue } = await sb.from("cases")
      .update({ email_verify_hash: await sha256hex(key), email_verify_sent_at: new Date().toISOString() })
      .eq("id", caseId).or(`email_verify_sent_at.is.null,email_verify_sent_at.lt.${tenAgo}`).select("id");
    if (ue) return json({ error: "save" }, 500);
    if (!claimed || !claimed.length) return json({ sent: false, reason: "too_soon" });
    // 佔位成功才取寄信額度；額度用完就把佔位還原，不浪費額度、也不讓人卡住冷卻時間
    if (!(await budget("verify"))) {
      await sb.from("cases").update({ email_verify_hash: c.email_verify_hash, email_verify_sent_at: c.email_verify_sent_at }).eq("id", caseId);
      return json({ sent: false, reason: "throttled" });
    }
    const link = `${SITE}#/verify-email?c=${caseId}&k=${key}`;
    // 信裡不放使用者填的文字（案件名稱），避免被拿來夾帶廣告或詐騙訊息
    const text = [`你好，你在${SITE_NAME}登記了走失協尋，並留下這個 Email。`, "",
      "請點下面的連結確認這是你的信箱。確認之後，有人回報看到牠，我們會馬上寄信通知你：", link, "",
      "連結 7 天內有效。", "不是你登記的？直接刪除這封信就好，我們不會再寄信給你。", "", `— ${SITE_NAME}　${SITE}`].join("\n");
    const html = `<!DOCTYPE html><html lang="zh-Hant"><body style="margin:0;background:#EFF2EE;font-family:'PingFang TC','Microsoft JhengHei',sans-serif;color:#141E22">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#fff;border-radius:16px;overflow:hidden">
<tr><td style="background:#CC3F1E;padding:18px 24px;color:#fff;font-size:22px;font-weight:900">🐾 ${SITE_NAME}</td></tr>
<tr><td style="padding:26px 24px 8px">
<p style="margin:0 0 12px;font-size:22px;font-weight:900">請確認你的信箱</p>
<p style="margin:0 0 22px;font-size:17px;line-height:1.7;color:#36454B">你在${SITE_NAME}登記了走失協尋。點下面的按鈕確認這是你的信箱，之後有人回報看到牠，我們會馬上寄信通知你。</p>
<a href="${link}" style="display:block;background:#CC3F1E;color:#fff;text-decoration:none;font-size:20px;font-weight:900;padding:16px 20px;border-radius:12px;text-align:center">✅ 確認信箱</a>
<p style="margin:18px 0 0;font-size:15px;line-height:1.7;color:#36454B">連結 7 天內有效。</p></td></tr>
<tr><td style="padding:18px 24px 24px"><p style="margin:0;font-size:13px;line-height:1.7;color:#5A6A70;border-top:1px solid #E3E7E2;padding-top:14px">
不是你登記的？直接刪除這封信就好，我們不會再寄信給你。<br>${SITE_NAME}｜全台走失毛孩協尋平台　<a href="${SITE}" style="color:#CC3F1E">wangmiaotw.com</a></p></td></tr>
</table></td></tr></table></body></html>`;
    try {
      await sendMail(to, `【${SITE_NAME}】請確認你的信箱，才收得到目擊通知`, text, html);
      await sb.from("case_mail_log").insert({ case_id: caseId, to_email: toKey, kind: "verify" });
      return json({ sent: true });
    } catch (e) {
      await sb.from("cases").update({ email_verify_hash: c.email_verify_hash, email_verify_sent_at: c.email_verify_sent_at }).eq("id", caseId);
      await budgetBack("verify");
      console.error("verify send failed", String(e));
      return json({ sent: false, reason: "send_failed" }, 502);
    }
  }

  // ---------------------------------------------------------------- 目擊通知
  if (!c.email_verified) return json({ sent: false, reason: "unverified" });
  if (c.status !== "searching") return json({ sent: false, reason: "not_searching" });
  // 同一案件一天最多 20 封目擊通知
  if (await count((x) => x.eq("case_id", caseId).eq("kind", "notify").gte("sent_at", new Date(Date.now() - 24 * 3600e3).toISOString())) >= 20)
    return json({ sent: false, reason: "throttled" });
  // 目擊通知全站每小時最多 150 封（和確認信分開計算）
  if (await count((x) => x.eq("kind", "notify").gte("sent_at", hourAgo)) >= 150) return json({ sent: false, reason: "throttled" });
  // 同一案件、同一信箱一小時最多 6 封；超過就先不寄，目擊留著下次一起寄
  if (await count((x) => x.eq("case_id", caseId).neq("kind", "push").gte("sent_at", hourAgo)) >= 6) return json({ sent: false, reason: "throttled" });
  if (await count((x) => x.eq("to_email", toKey).gte("sent_at", hourAgo)) >= 6) return json({ sent: false, reason: "throttled" });

  // 先「搶」下尚未通知的目擊（原子更新），避免同時兩次呼叫重複寄
  const since = new Date(Date.now() - 6 * 3600e3).toISOString();   // 被限流延後的目擊，6 小時內都會補寄
  const { data: ss, error: se } = await sb.from("sightings")
    .update({ notified: true })
    .eq("case_id", caseId).eq("notified", false).neq("status", "rejected").gte("created_at", since)
    .select("id,seen_at,place_text,direction,note,lat,lng,reporter_name,reporter_contact,photo_url");
  if (se) return json({ error: "claim" }, 500);
  if (!ss || !ss.length) return json({ sent: false, reason: "nothing_new" });
  // 每日寄信預算用完：把目擊放回「未通知」（排程之後會補寄），不佔用登入信的額度
  if (!(await budget("notify"))) {
    await sb.from("sightings").update({ notified: false }).in("id", ss.map((x) => x.id));
    return json({ sent: false, reason: "throttled" });
  }

  // 信件專用管理鑰匙（30 天有效）：點信裡的按鈕就能直接管理，不用另外找管理網址
  let mk = "";
  try { const { data } = await sb.rpc("issue_mail_key", { p_case: caseId }); if (typeof data === "string" && /^[0-9a-f]{48}$/.test(data)) mk = data; } catch (_) { /* 沒有鑰匙就用一般連結 */ }
  const manageUrl = `${SITE}#/manage/${caseId}${mk ? "?m=" + mk : ""}`;
  const lines = [`你的毛孩「${c.name}」剛剛有 ${ss.length} 筆新的目擊回報：`, ""];
  for (const s of ss) {
    lines.push(`・${fmt(s.seen_at)}  ${s.place_text || "（見地圖）"}  ${s.direction ? "往" + s.direction : ""}`);
    if (s.note) lines.push(`  狀況：${s.note}`);
    if (s.lat) lines.push(`  地圖：https://www.google.com/maps?q=${(+s.lat).toFixed(5)},${(+s.lng).toFixed(5)}`);
    if (s.photo_url) lines.push(`  照片：${s.photo_url}`);
    lines.push(`  回報者：${s.reporter_name || "匿名"}${s.reporter_contact ? "，聯絡方式：" + s.reporter_contact : ""}`);
    lines.push("");
  }
  lines.push("以上是網友填寫的內容，請自行判斷真假；本站不會要你匯款或提供密碼。",
    "確認後才會顯示在公開地圖上，點下面的網址就能直接到管理頁處理（30 天內有效，請勿轉傳）：",
    manageUrl, "", "看到牠時請不要呼喊或追趕，慢慢靠近、蹲低、用食物引導。", "", `— ${SITE_NAME}`);

  // 信件版面（HTML）：照片直接顯示在信裡、地圖和管理頁用大按鈕；網友填的文字一律跳脫
  const okPhoto = (u: string) => typeof u === "string" && u.startsWith(Deno.env.get("SUPABASE_URL") + "/storage/v1/object/public/photos/");
  const btn = (href: string, label: string, bg: string, fg = "#fff", border = bg) =>
    `<a href="${escH(href)}" style="display:block;background:${bg};color:${fg};border:2px solid ${border};text-decoration:none;font-size:17px;font-weight:800;padding:13px 16px;border-radius:12px;text-align:center;margin:8px 0 0">${label}</a>`;
  const items = ss.map((s) => {
    const map = s.lat ? `https://www.google.com/maps?q=${(+s.lat).toFixed(5)},${(+s.lng).toFixed(5)}` : "";
    const rows: [string, string][] = [["時間", fmt(s.seen_at)], ["地點", s.place_text || (s.lat ? "（看地圖）" : "未標示")]];
    if (s.direction) rows.push(["方向", "往" + s.direction]);
    if (s.note) rows.push(["狀況", s.note]);
    rows.push(["回報者", (s.reporter_name || "匿名") + (s.reporter_contact ? "（" + s.reporter_contact + "）" : "")]);
    return `<tr><td style="padding:16px 24px 6px">
${okPhoto(s.photo_url) ? `<a href="${escH(s.photo_url)}"><img src="${escH(s.photo_url)}" alt="目擊照片" width="432" style="display:block;width:100%;max-width:432px;height:auto;border-radius:12px;margin:0 0 12px;background:#EEE"></a>` : ""}
<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:16px;line-height:1.6;color:#36454B">
${rows.map(([k, v]) => `<tr><td style="width:64px;vertical-align:top;color:#5A6A70;font-weight:700;padding:2px 0">${k}</td><td style="padding:2px 0">${escH(v)}</td></tr>`).join("")}
</table>
${map ? btn(map, "📍 在 Google 地圖看位置", "#ffffff", "#CC3F1E", "#CC3F1E") : ""}
</td></tr>`;
  }).join(`<tr><td style="padding:6px 24px"><div style="border-top:1px solid #E3E7E2"></div></td></tr>`);
  const html = `<!DOCTYPE html><html lang="zh-Hant"><body style="margin:0;background:#EFF2EE;font-family:'PingFang TC','Microsoft JhengHei',sans-serif;color:#141E22">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#fff;border-radius:16px;overflow:hidden">
<tr><td style="background:#CC3F1E;padding:18px 24px;color:#fff;font-size:22px;font-weight:900">🐾 ${SITE_NAME}</td></tr>
<tr><td style="padding:22px 24px 4px"><p style="margin:0;font-size:22px;font-weight:900">有人看到${escH(c.name)}了！</p>
<p style="margin:6px 0 0;font-size:16px;color:#36454B">剛剛有 ${ss.length} 筆新的目擊回報：</p></td></tr>
${items}
<tr><td style="padding:14px 24px 6px">${btn(manageUrl, "到管理頁確認這筆目擊", "#CC3F1E")}
<p style="margin:10px 0 0;font-size:14px;line-height:1.7;color:#5A6A70">確認後才會顯示在公開地圖上。這個按鈕 30 天內都能直接進入管理，<b>請勿轉寄這封信</b>。</p></td></tr>
<tr><td style="padding:12px 24px 24px"><p style="margin:0;font-size:13px;line-height:1.7;color:#5A6A70;border-top:1px solid #E3E7E2;padding-top:14px">
以上是網友填寫的內容，請自行判斷真假；本站不會要你匯款或提供密碼。<br>看到牠時請不要呼喊或追趕，慢慢靠近、蹲低、用食物引導。<br>${SITE_NAME}｜全台走失毛孩協尋平台　<a href="${SITE}" style="color:#CC3F1E">wangmiaotw.com</a></p></td></tr>
</table></td></tr></table></body></html>`;

  try {
    await sendMail(to, `【${SITE_NAME}】有人看到${c.name}了！`, lines.join("\n"), html);
    await sb.from("case_mail_log").insert({ case_id: caseId, to_email: toKey });
    return json({ sent: true, count: ss.length });
  } catch (e) {
    // 寄失敗：還原成未通知，之後的每日排程或下次呼叫會再寄
    await sb.from("sightings").update({ notified: false }).in("id", ss.map((s: { id: string }) => s.id));
    await budgetBack("notify");
    console.error("send failed", String(e));
    return json({ sent: false, reason: "send_failed" }, 502);
  }
});

// 汪喵回家 — 每日自動化（排程）v2.0.0
// 由 scripts/daily.py v1.9.0 移植而來；改由 Supabase 自己的排程（pg_cron）呼叫，不再吃 GitHub Actions 額度。
//
// 網址：POST https://<project>.supabase.co/functions/v1/daily-run
//   body：{"mode":"nightly" | "notify" | "cleanup" | "cleanup-dry" | "match" | "all" | "probe"}
//   header：x-run-secret: <Vault 裡的 daily_run_secret>（排程 SQL 會自動帶上）
//
// mode 說明
//   nightly      每天 03:17：收容所比對、拾獲比對、飼主通知、會員通知（含附近彙整）、檢舉通知、到期提醒、定期清理
//   cleanup      每天 03:47：清掉沒人用的公開照片（和 nightly 分開跑，避免單次執行太久）
//   notify       每 2 小時：拾獲比對＋飼主／會員／檢舉通知
//   all          = nightly + cleanup（手動補跑用）
//   match / probe / cleanup-dry 和舊腳本相同
//
// 部署：Supabase → Edge Functions → 建立 daily-run，貼上本檔，並「關閉 Verify JWT」（改用 x-run-secret 驗證）。
// Secrets（Supabase → Edge Functions → Secrets）：RESEND_API_KEY（已有）；選填 MOA_API_URL、ADMIN_EMAIL、GMAIL_USER
// 每次執行的結果會寫到 Edge Functions → daily-run → Logs。

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
const SITE_URL = "https://wangmiaotw.com/";
const SITE_NAME = "汪喵回家";
const MAIL_FROM = "noreply@wangmiaotw.com", REPLY_TO = "service@wangmiaotw.com";
const RESEND_KEY = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const MAIL_OK = !!RESEND_KEY;
const MOA_API_URL = (Deno.env.get("MOA_API_URL") ?? "").trim();
const ADMIN_EMAIL = (Deno.env.get("ADMIN_EMAIL") ?? Deno.env.get("GMAIL_USER") ?? "").trim() || REPLY_TO;
const UA = "WangHome/2.0 (+lost-dog-matcher)";
const VERSION = "2.0.0";

function serviceKey(): string {
  try {
    const j = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    const k = j.default ?? Object.values(j)[0];
    if (typeof k === "string" && k) return k;
  } catch (_) { /* ignore */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}
const SERVICE_KEY = serviceKey();

// ---------------------------------------------------------------- 執行紀錄
let LOG: string[] = [];
const log = (...a: unknown[]) => {
  const s = a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ");
  LOG.push(s);
  console.log(s);
};
const errName = (e: unknown) => (e instanceof Error ? e.name + (e.message ? ": " + e.message.slice(0, 120) : "") : String(e).slice(0, 120));

// ---------------------------------------------------------------- Supabase REST
type Params = Record<string, string>;
function authHeaders(): Record<string, string> {
  const h: Record<string, string> = { apikey: SERVICE_KEY };
  if (SERVICE_KEY.startsWith("eyJ")) h["Authorization"] = `Bearer ${SERVICE_KEY}`;
  return h;
}
class HttpError extends Error {
  constructor(public status: number, msg: string) { super(msg); this.name = `HTTP ${status}`; }
}
// deno-lint-ignore no-explicit-any
async function sb(method: string, path: string, body?: unknown, params?: Params, prefer?: string): Promise<any> {
  let url = `${SUPABASE_URL}/rest/v1/${path}`;
  if (params) url += (path.includes("?") ? "&" : "?") + new URLSearchParams(params).toString();
  const r = await fetch(url, {
    method,
    headers: { ...authHeaders(), "Content-Type": "application/json", Prefer: prefer ?? "return=representation" },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60_000),
  });
  const t = await r.text();
  if (!r.ok) {
    let msg = "(非 JSON 回應)";
    try { const j = JSON.parse(t); msg = `code=${j.code} message=${String(j.message ?? "").slice(0, 120)}`; } catch (_) { /* ignore */ }
    log(`Supabase 回應 ${r.status}：${msg}`);
    throw new HttpError(r.status, msg);
  }
  return t ? JSON.parse(t) : null;
}
// PostgREST 單次最多回 1000 筆；分頁抓完整清單
// deno-lint-ignore no-explicit-any
async function sbAll(path: string, params: Params, page = 1000, cap = 50000, strict = false): Promise<any[]> {
  // deno-lint-ignore no-explicit-any
  const out: any[] = [];
  let off = 0;
  while (true) {
    if (off >= cap) {
      if (strict) throw new Error(`${path} 超過 ${cap} 筆，資料可能不完整`);
      break;
    }
    const p: Params = { order: "id", ...params, limit: String(page), offset: String(off) };
    const rows = (await sb("GET", path, undefined, p)) ?? [];
    out.push(...rows);
    if (!rows.length) break;
    off += rows.length;
  }
  return out;
}
const chunks = <T>(a: T[], n: number) => Array.from({ length: Math.ceil(a.length / n) }, (_, i) => a.slice(i * n, i * n + n));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- 農業部資料
// deno-lint-ignore no-explicit-any
async function fetchMoa(): Promise<any[]> {
  const url = MOA_API_URL || "https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=QcbUEzN6E6DL";
  const r = await fetch(url, { headers: { "User-Agent": UA, Accept: "application/json" }, signal: AbortSignal.timeout(25_000) });
  if (!r.ok) throw new HttpError(r.status, "moa");
  // deno-lint-ignore no-explicit-any
  let data: any = JSON.parse((await r.text()).replace(/^﻿/, ""));
  if (data && !Array.isArray(data)) {
    for (const k of ["data", "result", "records"]) if (Array.isArray(data[k])) { data = data[k]; break; }
  }
  if (!Array.isArray(data)) data = [];
  log(`農業部資料筆數：${data.length}`);
  return data;
}

// 「台」「臺」一律當成同一個字
const normCity = (s?: string | null) => (s ?? "").trim().replaceAll("台", "臺");

const COLOUR_GROUPS: Record<string, string[]> = {
  "黑": ["黑"], "白": ["白"], "黃": ["黃", "米", "淺棕", "卡其", "金"], "棕": ["棕", "咖啡", "褐", "茶"],
  "虎斑": ["虎斑", "斑"], "灰": ["灰", "銀"], "花": ["花", "三色", "黑白", "黃白", "雙色"], "紅": ["紅", "橘"],
};
function colourTokens(s?: string | null): Set<string> {
  const str = s ?? "";
  const out = new Set<string>();
  for (const [g, kws] of Object.entries(COLOUR_GROUPS)) if (kws.some((k) => str.includes(k))) out.add(g);
  return out;
}
const intersects = (a: Set<string>, b: Set<string>) => [...a].some((x) => b.has(x));

const SIZE_MAP: Record<string, string> = { small: "SMALL", medium: "MEDIUM", large: "BIG" };
const SEX_MAP: Record<string, string> = { male: "M", female: "F" };
const clamp = (s: number) => Math.max(0, Math.min(100, s));

// 粗略相似度 0~100；狗比狗、貓比貓，只看還在收容所的
// deno-lint-ignore no-explicit-any
function score(c: any, a: any): number {
  const want = c.species === "cat" ? "貓" : "狗";
  if ((a.animal_kind ?? "") !== want) return -1;
  if ((a.animal_status || "OPEN") !== "OPEN") return -1;
  let s = 0;
  const city = normCity(c.lost_city);
  const place = normCity(a.animal_foundplace) + normCity(a.shelter_address) + normCity(a.animal_place);
  if (!city || !place.includes(city)) return -1;   // 跨縣市先不比對
  s += 30;
  const lostDt = String(c.lost_at ?? "").slice(0, 10);
  const foundDt = String(a.animal_createtime || a.animal_opendate || "").slice(0, 10).replaceAll("/", "-");
  let lostM1 = lostDt;
  const t = Date.parse(lostDt + "T00:00:00Z");
  if (!Number.isNaN(t)) lostM1 = new Date(t - 86400e3).toISOString().slice(0, 10);
  if (foundDt && foundDt < lostM1) return -1;
  s += 10;
  const ct = colourTokens(c.colour), at = colourTokens(a.animal_colour);
  if (ct.size && at.size) {
    if (!intersects(ct, at)) return -1;
    s += 25;
  }
  if (c.size && a.animal_bodytype) s += SIZE_MAP[c.size] === a.animal_bodytype ? 15 : -10;
  if (c.sex in SEX_MAP && (a.animal_sex === "M" || a.animal_sex === "F")) s += SEX_MAP[c.sex] === a.animal_sex ? 15 : -20;
  const d = c.lost_district ?? "";
  if (d && place.includes(d)) s += 15;
  return clamp(s);
}

async function runMatching() {
  // 農業部開放資料只接受台灣 IP（Supabase 東京也連不上）；收容所比對在瀏覽器端進行。
  // 只有設定了 MOA_API_URL（例如台灣的代理）才在這裡跑。
  if (!MOA_API_URL) { log("收容所比對：由網站前端執行（未設定 MOA_API_URL，略過）"); return; }
  const cases = await sbAll("cases", { select: "id,name,species,lost_city,lost_district,lost_at,colour,size,sex,contact_email", status: "eq.searching", hidden: "eq.false" });
  if (!cases.length) { log("沒有協尋中案件"); return; }
  // deno-lint-ignore no-explicit-any
  let animals: any[];
  try { animals = await fetchMoa(); } catch (e) { log("抓取農業部資料失敗：", errName(e)); return; }
  const existing = await sbAll("shelter_matches", { select: "id,case_id,animal_id" });
  const seen = new Set(existing.map((m) => `${m.case_id}|${m.animal_id}`));
  // deno-lint-ignore no-explicit-any
  const rows: any[] = [];
  for (const c of cases) {
    for (const a of animals) {
      const sc = score(c, a);
      if (sc < 45) continue;
      const aid = String(a.animal_id);
      const key = `${c.id}|${aid}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const photo = String(a.album_file ?? "");
      const ages: Record<string, string> = c.species === "cat" ? { CHILD: "幼貓", ADULT: "成貓" } : { CHILD: "幼犬", ADULT: "成犬" };
      rows.push({
        case_id: c.id, animal_id: aid, animal_subid: a.animal_subid ?? null,
        shelter_name: a.shelter_name ?? null, shelter_tel: a.shelter_tel ?? null,
        shelter_address: a.shelter_address ?? null, found_place: a.animal_foundplace ?? null,
        colour: a.animal_colour ?? null,
        bodytype: ({ SMALL: "小型", MEDIUM: "中型", BIG: "大型" } as Record<string, string>)[a.animal_bodytype] ?? a.animal_bodytype ?? null,
        sex: ({ M: "公", F: "母" } as Record<string, string>)[a.animal_sex] ?? "不明",
        age: ages[a.animal_age] ?? a.animal_age ?? null,
        variety: a.animal_Variety || a.animal_variety || null,
        photo_url: photo.startsWith("http") ? photo : null,
        open_date: a.animal_opendate || null, score: sc,
      });
    }
  }
  if (rows.length) await sb("POST", "shelter_matches?on_conflict=case_id,animal_id", rows, undefined, "return=minimal,resolution=ignore-duplicates");
  log(`新增比對 ${rows.length} 筆`);
}

// ---------------------------------------------------------------- 拾獲通報 ↔ 案件
function km(aLat: number, aLng: number, bLat: number, bLng: number) {
  const R = 6371, r = (x: number) => (x * Math.PI) / 180;
  const h = Math.sin(r(bLat - aLat) / 2) ** 2 + Math.cos(r(aLat)) * Math.cos(r(bLat)) * Math.sin(r(bLng - aLng) / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
// 與前端 matchScore() 同邏輯
// deno-lint-ignore no-explicit-any
function foundScore(c: any, f: any): number {
  if (normCity(c.lost_city) !== normCity(f.city)) return -1;
  if ((c.species || "dog") !== (f.species || "dog")) return -1;
  const lost = Date.parse(c.lost_at ?? ""), seenAt = Date.parse(f.seen_at ?? "");
  if (!Number.isNaN(lost) && !Number.isNaN(seenAt)) {
    if (seenAt < lost - 86400e3 || seenAt > lost + 60 * 86400e3) return -1;
  }
  let s = 30;
  const a = colourTokens(c.colour), b = colourTokens(f.colour);
  if (a.size && b.size) {
    if (!intersects(a, b)) return -1;
    s += 25;
  }
  if (c.size && f.size) s += c.size === f.size ? 15 : -10;
  if ((c.sex === "male" || c.sex === "female") && (f.sex === "male" || f.sex === "female")) s += c.sex === f.sex ? 15 : -20;
  if (c.lost_district && c.lost_district === f.district) s += 10;
  if (c.lost_lat && f.lat) {
    const d = km(Number(c.lost_lat), Number(c.lost_lng), Number(f.lat), Number(f.lng));
    s += d < 2 ? 15 : d < 5 ? 8 : d > 20 ? -10 : 0;
  }
  return clamp(s);
}

async function runFoundMatching() {
  const cases = await sbAll("cases", { select: "id,species,lost_city,lost_district,lost_at,lost_lat,lost_lng,colour,size,sex", status: "eq.searching", hidden: "eq.false" });
  const founds = await sbAll("found_reports", { select: "id,species,city,district,seen_at,lat,lng,colour,size,sex", status: "eq.open", hidden: "eq.false" });
  if (!cases.length || !founds.length) { log("拾獲比對：無資料"); return; }
  const existing = await sbAll("found_matches", { select: "id,case_id,found_id" });
  const seen = new Set(existing.map((m) => `${m.case_id}|${m.found_id}`));
  // deno-lint-ignore no-explicit-any
  const rows: any[] = [];
  for (const c of cases) for (const f of founds) {
    const sc = foundScore(c, f);
    if (sc >= 45 && !seen.has(`${c.id}|${f.id}`)) rows.push({ case_id: c.id, found_id: f.id, score: sc });
  }
  if (rows.length) await sb("POST", "found_matches?on_conflict=case_id,found_id", rows, undefined, "return=minimal,resolution=ignore-duplicates");
  log(`拾獲比對新增 ${rows.length} 筆`);
}

// ---------------------------------------------------------------- Email
// Resend 免費版一天 100 封，登入信也走同一個帳號：網站通知一天最多 60 封（保留 40 封給登入信）。
// 會員通知（附近走失、追蹤、到期提醒）最多用到當天第 40 封，飼主的目擊通知永遠有保留額度。
const MAIL_CAP_HIGH = 60, MAIL_CAP_LOW = 40;
const KIND_CAP: Record<string, number> = { notify: 45, shelter: 45, found: 45, nearby: 40, follow: 40, due: 40, admin: 5 };
let STOP_MAIL = false;   // 這次執行中寄信出錯（例如額度用完、金鑰錯）就不再嘗試

async function mailBudget(kind: string, cap: number) {
  try { return (await sb("POST", "rpc/mail_budget_take", { p_kind: kind, p_cap: cap, p_kind_cap: Math.min(cap, KIND_CAP[kind] ?? 40) })) === true; }
  catch (e) { log("查寄信額度失敗，這次先不寄：", errName(e)); return false; }
}

class RecipientError extends Error { constructor(m: string) { super(m); this.name = "RecipientError"; } }
async function resendSend(to: string, subject: string, text: string, html?: string) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: `${SITE_NAME} <${MAIL_FROM}>`, to: [to], reply_to: REPLY_TO, subject, text, ...(html ? { html } : {}) }),
    signal: AbortSignal.timeout(30_000),
  });
  if (r.ok) return true;
  const t = (await r.text()).slice(0, 200);
  // 422：這個收件地址有問題 → 只跳過這封；其他（401 金鑰錯、429 額度、5xx）→ 停止這一輪寄信
  if (r.status === 422 || r.status === 400) throw new RecipientError(`resend ${r.status} ${t}`);
  throw new HttpError(r.status, `resend ${t}`);
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
  const base = Deno.env.get("SUPABASE_URL")!, key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
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
        if (r.status === 410 || /BadDeviceToken|Unregistered|DeviceTokenNotForTopic/.test(why))
          await fetch(`${base}/rest/v1/push_tokens?token=eq.${encodeURIComponent(t.token)}`, { method: "DELETE", headers: h }).catch(() => {});
      }
    } catch (_) { /* 推播失敗不影響寄信 */ }
  }
  return n;
}

async function sendMail(to: string, subject: string, body: string, kind = "notify", cap = MAIL_CAP_HIGH, html?: string): Promise<boolean> {
  if (!(MAIL_OK && to) || STOP_MAIL) return false;
  if (!(await mailBudget(kind, cap))) { log(`今天的寄信額度已用完（${kind}），留到明天再寄`); return false; }
  try {
    return await resendSend(to, subject, body, html);
  } catch (e) {
    try { await sb("POST", "rpc/mail_budget_return", { p_kind: kind }); } catch (_) { /* ignore */ }
    if (!(e instanceof RecipientError)) STOP_MAIL = true;
    throw e;
  }
}

// 跟 notify-sighting 一樣的信箱正規化（Gmail 去點、去 +tag），寄信上限才算同一個人
function normMail(e?: string | null) {
  const s = (e ?? "").trim().toLowerCase();
  const at = s.indexOf("@");
  if (at < 0) return s;
  let u = s.slice(0, at), d = s.slice(at + 1);
  if (d === "googlemail.com") d = "gmail.com";
  u = u.split("+")[0];
  if (d === "gmail.com") u = u.replaceAll(".", "");
  return `${u}@${d}`;
}

// 寄給「案件飼主信箱」的上限（和 notify-sighting 共用 case_mail_log）：同一信箱每小時 6 封、全站每小時 150 封
async function caseMailOk(to: string) {
  const hour = new Date(Date.now() - 3600e3).toISOString();
  const cnt = async (params: Params) => {
    const url = `${SUPABASE_URL}/rest/v1/case_mail_log?` + new URLSearchParams({ ...params, select: "case_id" }).toString();
    const r = await fetch(url, { method: "HEAD", headers: { ...authHeaders(), Prefer: "count=exact" }, signal: AbortSignal.timeout(30_000) });
    if (!r.ok) throw new HttpError(r.status, "count");
    const last = (r.headers.get("Content-Range") ?? "*/0").split("/").pop() ?? "0";
    return last === "*" ? 0 : Number(last) || 0;
  };
  try {
    return (await cnt({ to_email: `eq.${normMail(to)}`, sent_at: `gte.${hour}` })) < 6 && (await cnt({ sent_at: `gte.${hour}` })) < 150;
  } catch (e) { log("查寄信上限失敗，這次先不寄：", errName(e)); return false; }
}

// 寄給案件飼主：只寄已確認的信箱、遵守上限、寄完記錄。回傳 true 才算寄出
// deno-lint-ignore no-explicit-any
async function sendCaseMail(c: any, subject: string, body: string, html?: string) {
  const to = String(c.contact_email ?? "").trim().toLowerCase();
  if (!to || !c.email_verified) return false;
  if (!(await caseMailOk(to))) { log("達寄信上限，下次再寄：", c.name); return false; }
  if (!(await sendMail(to, subject, body, "notify", MAIL_CAP_HIGH, html))) return false;
  try { await sb("POST", "case_mail_log", { case_id: c.id, to_email: normMail(to) }, undefined, "return=minimal"); }
  catch (e) { log("寫入寄信紀錄失敗：", errName(e)); }
  return true;
}

// 台灣時間 MM/DD HH:MM
function fmt(ts?: string | null) {
  const t = Date.parse(ts ?? "");
  if (Number.isNaN(t)) return ts ?? "";
  const d = new Date(t + 8 * 3600e3);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getUTCMonth() + 1)}/${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
}

// 把已處理（或不可能寄出）的紀錄標記為已通知；失敗重試一次，還是失敗就記下、繼續
async function markNotified(table: string, ids: string[]) {
  for (const part of chunks(ids, 150)) {
    for (const attempt of [1, 2]) {
      try { await sb("PATCH", table, { notified: true }, { id: `in.(${part.join(",")})` }, "return=minimal"); break; }
      catch (e) {
        if (attempt === 2) log(`標記已通知失敗（${table}，${part.length} 筆），下一輪可能重寄：`, errName(e));
        else await sleep(3000);
      }
    }
  }
}

// 管理頁網址，附信件專用鑰匙（30 天有效）；同一輪同一案件只產生一把
const MK = new Map<string, string>();
async function manageUrl(cid: string) {
  if (!MK.has(cid)) {
    try {
      const k = await sb("POST", "rpc/issue_mail_key", { p_case: cid });
      MK.set(cid, typeof k === "string" && /^[0-9a-f]{48}$/.test(k) ? k : "");
    } catch (e) { log("產生信件鑰匙失敗（改用一般網址）：", errName(e)); MK.set(cid, ""); }
  }
  const k = MK.get(cid)!;
  return `${SITE_URL}#/manage/${cid}` + (k ? `?m=${k}` : "");
}

const E = (x: unknown) => String(x ?? "").replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#x27;" }[ch]!));

// 目擊通知的信件版面：照片直接顯示、地圖與管理頁用大按鈕；網友填的文字一律跳脫
// deno-lint-ignore no-explicit-any
function sightingHtml(c: any, manage: string, lst: any[]) {
  const pub = `${SUPABASE_URL}/storage/v1/object/public/photos/`;
  const btn = (href: string, label: string, bg: string, fg = "#fff", border?: string) =>
    `<a href="${E(href)}" style="display:block;background:${bg};color:${fg};border:2px solid ${border ?? bg};text-decoration:none;` +
    `font-size:17px;font-weight:800;padding:13px 16px;border-radius:12px;text-align:center;margin:8px 0 0">${label}</a>`;
  const items = lst.map((s) => {
    const rows: [string, string][] = [["時間", fmt(s.seen_at)], ["地點", s.place_text || (s.lat ? "（看地圖）" : "未標示")]];
    if (s.direction) rows.push(["方向", "往" + s.direction]);
    if (s.note) rows.push(["狀況", s.note]);
    rows.push(["回報者", (s.reporter_name || "匿名") + (s.reporter_contact ? `（${s.reporter_contact}）` : "")]);
    const ph = s.photo_url ?? "";
    const img = typeof ph === "string" && ph.startsWith(pub)
      ? `<a href="${E(ph)}"><img src="${E(ph)}" alt="目擊照片" width="432" style="display:block;width:100%;max-width:432px;height:auto;border-radius:12px;margin:0 0 12px;background:#EEE"></a>`
      : "";
    const tbl = rows.map(([k, v]) => `<tr><td style="width:64px;vertical-align:top;color:#5A6A70;font-weight:700;padding:2px 0">${k}</td><td style="padding:2px 0">${E(v)}</td></tr>`).join("");
    const mp = s.lat ? btn(`https://www.google.com/maps?q=${Number(s.lat).toFixed(5)},${Number(s.lng).toFixed(5)}`, "📍 在 Google 地圖看位置", "#ffffff", "#CC3F1E", "#CC3F1E") : "";
    return `<tr><td style="padding:16px 24px 6px">${img}<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;font-size:16px;line-height:1.6;color:#36454B">${tbl}</table>${mp}</td></tr>`;
  });
  const sep = '<tr><td style="padding:6px 24px"><div style="border-top:1px solid #E3E7E2"></div></td></tr>';
  return `<!DOCTYPE html><html lang="zh-Hant"><body style="margin:0;background:#EFF2EE;font-family:'PingFang TC','Microsoft JhengHei',sans-serif;color:#141E22">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#fff;border-radius:16px;overflow:hidden">
<tr><td style="background:#CC3F1E;padding:18px 24px;color:#fff;font-size:22px;font-weight:900">🐾 ${SITE_NAME}</td></tr>
<tr><td style="padding:22px 24px 4px"><p style="margin:0;font-size:22px;font-weight:900">有人看到${E(c.name)}了！</p>
<p style="margin:6px 0 0;font-size:16px;color:#36454B">有 ${lst.length} 筆新的目擊回報：</p></td></tr>
${items.join(sep)}
<tr><td style="padding:14px 24px 6px">${btn(manage, "到管理頁確認這筆目擊", "#CC3F1E")}
<p style="margin:10px 0 0;font-size:14px;line-height:1.7;color:#5A6A70">確認後才會顯示在公開地圖上。這個按鈕 30 天內都能直接進入管理，<b>請勿轉寄這封信</b>。</p></td></tr>
<tr><td style="padding:12px 24px 24px"><p style="margin:0;font-size:13px;line-height:1.7;color:#5A6A70;border-top:1px solid #E3E7E2;padding-top:14px">
以上是網友填寫的內容，請自行判斷真假；本站不會要你匯款或提供密碼。<br>看到牠時請不要呼喊或追趕，慢慢靠近、蹲低、用食物引導。<br>${SITE_NAME}｜全台走失毛孩協尋平台　<a href="${SITE_URL}" style="color:#CC3F1E">wangmiaotw.com</a></p></td></tr>
</table></td></tr></table></body></html>`;
}

// deno-lint-ignore no-explicit-any
function groupBy<T extends Record<string, any>>(rows: T[], key: (r: T) => string) {
  const m = new Map<string, T[]>();
  for (const r of rows) { const k = key(r); if (!m.has(k)) m.set(k, []); m.get(k)!.push(r); }
  return m;
}

async function runNotifications() {
  if (!MAIL_OK) { log("未設定寄信，略過通知"); return; }
  const caseRows = await sbAll("cases", { select: "id,name,contact_email,hidden,email_verified,status", status: "eq.searching", hidden: "eq.false" }, 1000, 1e6, true);
  const cases = new Map(caseRows.map((c) => [c.id, c]));
  const oldCut = new Date(Date.now() - 3 * 86400e3).toISOString();
  // 信箱還沒確認：先不寄、留著；超過 3 天的就標記掉，不再累積
  // deno-lint-ignore no-explicit-any
  const skipUnverified = async (table: string, lst: any[], key = "created_at") => {
    const old = lst.filter((x) => x[key] && x[key] < oldCut).map((x) => x.id);
    if (old.length) await markNotified(table, old);
  };

  // 目擊：先「佔走」待通知的（原子更新），再寄；寄不出去的再還原成未通知
  // deno-lint-ignore no-explicit-any
  let pend: any[] = [];
  try {
    pend = (await sb("PATCH", "sightings", { notified: true }, { notified: "eq.false", status: "neq.rejected", select: "*" }, "return=representation")) ?? [];
  } catch (e) { log("佔位待通知目擊失敗：", errName(e)); }
  pend.sort((a, b) => String(a.created_at ?? "").localeCompare(String(b.created_at ?? "")));
  const unclaim = async (ids: string[]) => {
    for (const part of chunks(ids, 150)) {
      try { await sb("PATCH", "sightings", { notified: false }, { id: `in.(${part.join(",")})` }, "return=minimal"); }
      catch (e) { log("還原未通知失敗：", errName(e)); }
    }
  };
  for (const [cid, lst] of groupBy(pend, (s) => s.case_id)) {
    const c = cases.get(cid);
    if (!c || !c.contact_email || c.status !== "searching") continue;   // 已標記為已通知：本來就寄不出去
    const ids = lst.map((s) => s.id);
    if (!c.email_verified) { await unclaim(ids); await skipUnverified("sightings", lst); continue; }
    const to = String(c.contact_email).trim().toLowerCase();
    if (!(await caseMailOk(to))) { log("達寄信上限，下次再寄：", c.name); await unclaim(ids); continue; }
    const manage = await manageUrl(cid);
    const lines = [`你的案件「${c.name}」有 ${lst.length} 筆新的目擊回報：`, ""];
    for (const s of lst) {
      lines.push(`・${fmt(s.seen_at)}  ${s.place_text || "（見地圖）"}  ${s.direction ? "往" + s.direction : ""}`);
      if (s.note) lines.push(`  ${s.note}`);
      if (s.lat) lines.push(`  地圖 https://www.google.com/maps?q=${s.lat},${s.lng}`);
      if (s.reporter_contact) lines.push(`  回報者聯絡：${s.reporter_contact}`);
      lines.push("");
    }
    lines.push("請到管理頁確認後才會顯示在公開地圖（30 天內點這個網址就能直接管理，請勿轉傳）：", manage, "", `— ${SITE_NAME}`);
    try {
      if (!(await sendCaseMail(c, `【${SITE_NAME}】有人看到${c.name}了！`, lines.join("\n"), sightingHtml(c, manage, lst)))) { await unclaim(ids); continue; }
      log(`已通知目擊：${c.name} x${lst.length}`);
    } catch (e) { log("寄信失敗：", errName(e)); await unclaim(ids); continue; }
  }

  // 收容所比對
  const sm = await sbAll("shelter_matches", { select: "*", notified: "eq.false", dismissed: "eq.false", order: "score.desc" });
  for (const [cid, lst] of groupBy(sm, (m) => m.case_id)) {
    const c = cases.get(cid);
    if (!c || !c.contact_email || c.status !== "searching") { await markNotified("shelter_matches", lst.map((m) => m.id)); continue; }
    if (!c.email_verified) { await skipUnverified("shelter_matches", lst, "matched_at"); continue; }
    const lines = [`系統在收容所資料中找到 ${lst.length} 筆與「${c.name}」疑似相符的毛孩，請盡快親自確認：`, ""];
    for (const m of lst.slice(0, 10)) {
      const sc = m.score ?? 0;
      const sim = sc >= 80 ? "很像" : sc >= 60 ? "有點像" : "可能相關";
      if (m.shelter_tel) {   // 系統自己向農業部查到的（可信）
        lines.push(`・${m.shelter_name || "收容所"}（${sim}）  ${m.sex || ""} ${m.bodytype || ""} ${m.colour || ""}`);
        lines.push(`  拾獲地：${m.found_place || "未註明"}  電話：${m.shelter_tel}`);
      } else {               // 網友瀏覽時回報的：信裡不放任何網友可填的文字
        lines.push(`・收容所裡一隻疑似的毛孩（${sim}）`);
        lines.push(`  收容所電話與地址：請打開你的管理頁查看（會即時向農業部查詢）`);
      }
      if (m.photo_url) lines.push(`  照片：${m.photo_url}`);
      lines.push("");
    }
    lines.push("這只是粗略比對，請打電話到收容所提供晶片號碼核對，或親自到所比對。", `案件頁：${SITE_URL}#/case/${cid}`, "", `— ${SITE_NAME}`);
    try {
      if (!(await sendCaseMail(c, `【${SITE_NAME}】收容所有疑似 ${c.name} 的毛孩`, lines.join("\n")))) continue;
      log(`已通知比對：${c.name} x${lst.length}`);
    } catch (e) { log("寄信失敗：", errName(e)); continue; }
    await markNotified("shelter_matches", lst.map((m) => m.id));
  }

  // 拾獲通報比對
  const fm = await sbAll("found_matches", { select: "id,case_id,found_id,score,created_at", notified: "eq.false", order: "score.desc" });
  // deno-lint-ignore no-explicit-any
  const fr = new Map<string, any>();
  const fids = [...new Set(fm.map((m) => m.found_id))].sort();
  for (const part of chunks(fids, 100)) {
    const rows = (await sb("GET", "found_reports", undefined, { select: "id,kind,seen_at,city,district,place_text,colour,size,current_place,hidden", id: `in.(${part.join(",")})` })) ?? [];
    for (const f of rows) if (!f.hidden) fr.set(f.id, f);
  }
  for (const [cid, all] of groupBy(fm, (m) => m.case_id)) {
    const c = cases.get(cid);
    const lst = c ? all.filter((m) => fr.has(m.found_id)) : all;
    if (!c || !c.contact_email || !lst.length || c.status !== "searching") { await markNotified("found_matches", all.map((m) => m.id)); continue; }
    if (!c.email_verified) { await skipUnverified("found_matches", lst); continue; }
    const lines = [`有網友登記了 ${lst.length} 筆可能是「${c.name}」的拾獲／目擊通報：`, ""];
    for (const m of lst.slice(0, 10)) {
      const f = fr.get(m.found_id) ?? {};
      const kind = f.kind === "injured" ? "受傷" : f.kind === "found" ? "拾獲" : "目擊";
      lines.push(`・${kind}  相似 ${m.score}  ${fmt(f.seen_at ?? "")}  ${f.city ?? ""}${f.district || ""} ${f.place_text || ""}`);
      if (f.current_place) lines.push(`  目前在：${f.current_place}`);
      lines.push(`  ${SITE_URL}#/found/${m.found_id}`, "");
    }
    lines.push("請點連結看照片，並直接聯絡通報者。", "", `— ${SITE_NAME}`);
    try {
      if (!(await sendCaseMail(c, `【${SITE_NAME}】有人可能撿到／看到 ${c.name}`, lines.join("\n")))) continue;
      log(`已通知拾獲比對：${c.name} x${lst.length}`);
    } catch (e) { log("寄信失敗：", errName(e)); continue; }
    await markNotified("found_matches", lst.map((m) => m.id));
  }
}

// ---------------------------------------------------------------- 會員通知
const SP_NAME: Record<string, string> = { dog: "狗", cat: "貓" };
async function runMemberNotifications(nearby = true) {
  if (!MAIL_OK) { log("未設定寄信，略過會員通知"); return; }
  // 附近新案件：一天只寄一次彙整（每天凌晨那次）
  const near = nearby ? ((await sb("POST", "rpc/nearby_targets", { p_hours: 26 })) ?? []) : [];
  for (const lst of groupBy(near, (r) => `${r.user_id}|${r.email}`).values()) {
    const { user_id: uid, email } = lst[0];
    const lines = [`你家附近有 ${lst.length} 隻毛孩走失了，看到請拍照回報、不要追：`, ""];
    for (const r of lst.slice(0, 10)) {
      lines.push(`・${SP_NAME[r.species] ?? ""} ${r.case_name}（距離約 ${Number(r.distance_km).toFixed(1)} 公里）${r.lost_city}${r.lost_district || ""} ${r.lost_place || ""}`);
      lines.push(`  ${SITE_URL}#/case/${r.case_id}`);
    }
    if (lst.length > 10) lines.push("", `還有 ${lst.length - 10} 隻，到網站看全部：${SITE_URL}#/lost?near=1`);
    lines.push("", `不想再收到？到「我的 → 通知設定」關閉：${SITE_URL}#/me`, `— ${SITE_NAME}`);
    try {
      if (!(await sendMail(email, `【${SITE_NAME}】你家附近有毛孩走失`, lines.join("\n"), "nearby", MAIL_CAP_LOW))) break;
      await sb("POST", "notify_log", lst.map((r) => ({ user_id: uid, kind: "nearby", ref_id: r.case_id })), undefined, "return=minimal,resolution=ignore-duplicates");   // 全部記下來，超過 10 隻的隔天不會再寄
      log(`附近通知：${lst.length} 筆 → 1 位會員`);
      await pushToUser(uid, `你家附近有 ${lst.length} 隻毛孩走失`, `${lst[0].case_name}（約 ${Number(lst[0].distance_km).toFixed(1)} 公里）${lst.length > 1 ? "等" : ""}，出門時幫忙留意`, lst.length === 1 ? `#/case/${lst[0].case_id}` : "#/inbox");
    } catch (e) { log("附近通知寄送失敗：", errName(e)); }
  }
  // 追蹤案件新目擊
  const fol = (await sb("POST", "rpc/follow_targets", { p_hours: 26 })) ?? [];
  for (const lst of groupBy(fol, (r) => `${r.user_id}|${r.email}`).values()) {
    const { user_id: uid, email } = lst[0];
    const lines = ["你追蹤的案件有新的目擊：", ""];
    for (const r of lst.slice(0, 15)) {
      lines.push(`・${r.case_name}  ${fmt(r.seen_at)}  ${r.place_text || "（見地圖）"}`);
      lines.push(`  ${SITE_URL}#/case/${r.case_id}`);
    }
    lines.push("", `管理追蹤與通知：${SITE_URL}#/me`, `— ${SITE_NAME}`);
    try {
      if (!(await sendMail(email, `【${SITE_NAME}】追蹤的案件有新目擊`, lines.join("\n"), "follow", MAIL_CAP_LOW))) break;
      await sb("POST", "notify_log", lst.map((r) => ({ user_id: uid, kind: "follow", ref_id: r.sighting_id })), undefined, "return=minimal,resolution=ignore-duplicates");
      log(`追蹤通知：${lst.length} 筆 → 1 位會員`);
      await pushToUser(uid, `你追蹤的${lst[0].case_name}有新目擊`, `${lst[0].place_text || "點開看位置"}`, `#/case/${lst[0].case_id}`);
    } catch (e) { log("追蹤通知寄送失敗：", errName(e)); }
  }
}

// ---------------------------------------------------------------- 健康紀錄到期提醒
async function runDueReminders() {
  if (!MAIL_OK) return;
  const rows = (await sb("POST", "rpc/due_targets", {})) ?? [];
  const today = new Date(Date.now() + 8 * 3600e3).toISOString().slice(0, 10);   // 台灣日期
  const dayNum = (d: string) => Math.round(Date.parse(d + "T00:00:00Z") / 86400e3);
  for (const lst0 of groupBy(rows, (r) => `${r.user_id}|${r.email}`).values()) {
    const lst = [...lst0].sort((a, b) => String(a.next_due).localeCompare(String(b.next_due)));
    const { user_id: uid, email } = lst[0];
    const lines = ["毛孩的健康項目快到期了：", ""];
    for (const r of lst) {
      const d = dayNum(r.next_due) - dayNum(today);
      const when = d < 0 ? `已過期 ${-d} 天` : d === 0 ? "今天" : `${d} 天後`;
      lines.push(`・${r.pet_name}｜${r.title}　${r.next_due}（${when}）`);
    }
    lines.push("", `完成後到「我的」頁標記已完成：${SITE_URL}#/me`, `— ${SITE_NAME}`);
    try {
      // 主旨沿用舊版：用排序前的第一筆
      if (!(await sendMail(email, `【${SITE_NAME}】毛孩健康提醒：${lst0[0].pet_name} ${lst0[0].title}`, lines.join("\n"), "due", MAIL_CAP_LOW))) break;
      await sb("POST", "notify_log", lst.map((r) => ({ user_id: uid, kind: `due:${r.next_due}`, ref_id: r.record_id })), undefined, "return=minimal,resolution=ignore-duplicates");
      log(`到期提醒：${lst.length} 筆 → 1 位會員`);
    } catch (e) { log("到期提醒寄送失敗：", errName(e)); }
  }
}

// ---------------------------------------------------------------- 檢舉通知站長
async function runReportAlerts() {
  if (!(MAIL_OK && ADMIN_EMAIL)) return;
  const rows = await sbAll("reports", { select: "id,target_type,target_id,reason,note,created_at", notified: "eq.false", order: "created_at.asc" });
  if (!rows.length) return;
  const names: Record<string, string> = { case: "走失案件", found: "拾獲通報", sighting: "目擊" };
  const lines = [`有 ${rows.length} 則新檢舉待處理：`, ""];
  for (const r of rows.slice(0, 30)) lines.push(`・${names[r.target_type] ?? r.target_type}  原因：${r.reason}  ${r.note || ""}`);
  lines.push("", `管理後台：${SITE_URL}#/admin`, `— ${SITE_NAME}`);
  try {
    if (!(await sendMail(ADMIN_EMAIL, `【${SITE_NAME}】${rows.length} 則新檢舉`, lines.join("\n"), "admin"))) return;
    await markNotified("reports", rows.map((r) => r.id));
    log(`已通知站長 ${rows.length} 則檢舉`);
  } catch (e) { log("檢舉通知失敗：", errName(e)); }
}

// ---------------------------------------------------------------- 清掉沒人用的公開照片
// 只看 cases/、found/、sightings/ 三個資料夾；只刪「沒有任何資料用到」而且「上傳超過 12 小時」的檔案
const PUBLIC_PREFIX = "/storage/v1/object/public/photos/";
// deno-lint-ignore no-explicit-any
async function storage(method: string, path: string, body?: unknown): Promise<any> {
  const r = await fetch(`${SUPABASE_URL}/storage/v1/${path}`, {
    method,
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60_000),
  });
  const t = await r.text();
  if (!r.ok) throw new HttpError(r.status, `storage ${t.slice(0, 120)}`);
  return t ? JSON.parse(t) : null;
}

async function runPhotoCleanup(dry = false) {
  const used = new Set<string>();
  const add = (u: unknown) => {
    if (typeof u === "string" && u.includes(PUBLIC_PREFIX)) {
      let k = u.split(PUBLIC_PREFIX)[1].split("?")[0];
      try { k = decodeURIComponent(k); } catch (_) { /* ignore */ }
      used.add(k); used.add(k.replace(/\.jpg$/, "_t.jpg"));
    }
  };
  for (const r of await sbAll("cases", { select: "id,photos" }, 1000, 1e7, true)) for (const u of r.photos ?? []) add(u);
  for (const r of await sbAll("found_reports", { select: "id,photos" }, 1000, 1e7, true)) for (const u of r.photos ?? []) add(u);
  for (const r of await sbAll("sightings", { select: "id,photo_url" }, 1000, 1e7, true)) add(r.photo_url);
  if (!used.size) { log("照片清理：找不到任何使用中的照片，為了安全這次不刪"); return; }
  const cutoff = Date.now() - 12 * 3600e3;
  const stale: string[] = [];
  let total = 0, inUse = 0;
  for (const folder of ["cases", "found", "sightings"]) {
    let off = 0;
    while (true) {
      const items = (await storage("POST", "object/list/photos", { prefix: folder + "/", limit: 1000, offset: off, sortBy: { column: "name", order: "asc" } })) ?? [];
      for (const it of items) {
        const name = it.name ?? "";
        if (!name || it.id == null) continue;   // 子資料夾
        total++;
        const key = `${folder}/${name}`;
        const t = Date.parse(it.created_at || it.updated_at || "");
        const old = !Number.isNaN(t) && t < cutoff;
        if (used.has(key)) inUse++;
        else if (old) stale.push(key);
      }
      if (items.length < 1000) break;
      off += 1000;
    }
  }
  // 安全檢查：storage 裡一張「使用中」的照片都對不到，可能是程式出錯，這次不刪
  if (total > 20 && inUse === 0) { log(`照片清理：storage 裡找不到任何使用中的照片（共 ${total} 個檔案），為了安全這次不刪`); return; }
  log(`照片清理：共 ${total} 個檔案，使用中 ${Math.floor(used.size / 2)}，要刪 ${stale.length}`);
  if (dry) { log("（試跑，不刪除）", stale.slice(0, 20)); return; }
  for (const part of chunks(stale, 100)) await storage("DELETE", "object/photos", { prefixes: part });
}

// ---------------------------------------------------------------- 主流程
const MODES = ["all", "nightly", "notify", "match", "probe", "cleanup", "cleanup-dry"] as const;
type Mode = typeof MODES[number];

async function run(mode: Mode) {
  LOG = []; STOP_MAIL = false; MK.clear();
  log(`WangHome daily-run v${VERSION} mode = ${mode} ${new Date().toISOString()}`);
  if (mode === "probe") {
    try {
      const data = await fetchMoa();
      const dogs = data.filter((x) => (x.animal_kind ?? "") === "狗");
      log(`其中狗：${dogs.length} 筆`);
      if (data.length) log("欄位：", Object.keys(data[0]).sort().join(", "));
    } catch (e) { log("連不上農業部開放資料（多半是擋海外 IP）：", errName(e)); }
    return { ok: true, log: LOG };
  }
  const failed: string[] = [];
  const step = async (name: string, fn: () => Promise<unknown>) => {
    try { await fn(); } catch (e) { failed.push(name); log(`【${name}】失敗：`, errName(e)); }
  };
  const full = mode === "all" || mode === "nightly";
  try {
    if (full || mode === "match") await step("收容所比對", runMatching);
    if (full || mode === "match" || mode === "notify") await step("拾獲比對", runFoundMatching);
    if (full || mode === "notify") await step("飼主通知", runNotifications);
    if (full || mode === "notify") await step("會員通知", () => runMemberNotifications(full));
    if (full || mode === "notify") await step("檢舉通知", runReportAlerts);
    if (full) await step("到期提醒", runDueReminders);
    if (full) {
      await step("定期清理", async () => log("定期清理：", await sb("POST", "rpc/retention_cleanup", {})));
      await step("清除舊網路位址", async () => log("清除 30 天前的網路位址：", await sb("POST", "rpc/clear_old_ips", {})));
    }
    if (mode === "all" || mode === "cleanup" || mode === "cleanup-dry") await step("照片清理", () => runPhotoCleanup(mode === "cleanup-dry"));
  } finally {
    // 保活：免費專案 7 天沒有活動會被暫停
    try {
      const n = await sb("GET", "cases", undefined, { select: "id", limit: "1" });
      log("保活 OK", n?.length ? "有資料" : "空");
    } catch (e) { failed.push("保活"); log("保活失敗：", errName(e)); }
  }
  if (failed.length) log("這次有步驟失敗：", failed.join("、"));
  return { ok: !failed.length, failed, log: LOG };
}

// 只有帶著正確 x-run-secret 的呼叫才會執行（密碼存在 Supabase Vault，由資料庫函式比對）
async function secretOk(secret: string) {
  if (!secret || secret.length < 32) return false;
  try { return (await sb("POST", "rpc/daily_run_secret_ok", { p: secret })) === true; } catch (_) { return false; }
}

let RUNNING = false;
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  if (!SUPABASE_URL || !SERVICE_KEY) return new Response("not configured", { status: 500 });
  if (!(await secretOk(req.headers.get("x-run-secret") ?? ""))) return new Response("forbidden", { status: 403 });
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch (_) { /* ignore */ }
  const mode = (MODES as readonly string[]).includes(String(body.mode)) ? (body.mode as Mode) : "notify";
  if (RUNNING) return Response.json({ started: false, reason: "busy" }, { status: 409 });
  RUNNING = true;
  const task = run(mode).catch((e) => { console.error("daily-run 失敗：", errName(e)); return { ok: false }; }).finally(() => { RUNNING = false; });
  // 排程（pg_net）只等幾秒；工作放在背景繼續跑，結果看 Edge Functions → daily-run → Logs
  if (body.wait === true) return Response.json(await task);
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(task);
  return Response.json({ started: true, mode }, { status: 202 });
});

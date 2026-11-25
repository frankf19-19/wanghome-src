// 汪喵回家 — 自動發粉專貼文 v2.0.0
//   cases  ：每 30 分鐘。網友新登記、有照片、飼主同意分享的協尋案件 → FB 粉專＋IG（同一張照片）＋Threads（主題「狗狗走失／貓咪走失」）
//            站長（is_admin）自己登記的案件不自動發（站長會手動發整套）
//   weekly ：每週日晚上。「本週找回」整理 → 發到 FB 粉專
//   probe  ：只檢查權杖能不能用（不發文）
//
// 網址：POST https://<project>.supabase.co/functions/v1/social-post   body：{"mode":"cases"|"weekly"|"probe"}
// header：x-run-secret（和 daily-run 共用 Vault 裡的 daily_run_secret；排程 SQL 會自動帶上）
// Secrets（由站長自己貼到 Supabase → Edge Functions → Secrets，沒設的平台就略過）：
//   FB_PAGE_TOKEN ：粉專的長效存取權杖（FB＋連結的 IG）
//   THREADS_TOKEN ：Threads 的長效存取權杖（wangmiaotw）
// 部署：.github/workflows/fn-deploy.yml（關閉 Verify JWT）

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
const SITE = "https://wangmiaotw.com/";
const GRAPH = "https://graph.facebook.com/v21.0";
const TOKEN = (Deno.env.get("FB_PAGE_TOKEN") ?? "").trim();
const TH_TOKEN = (Deno.env.get("THREADS_TOKEN") ?? "").trim();
const THREADS = "https://graph.threads.net/v1.0";
const PER_RUN = 3;               // 每次最多發幾則，避免洗版
const WAIT_MIN = 20;             // 登記後至少等幾分鐘才發（給飼主改資料、給站方檢查）
const MAX_AGE_H = 72;            // 超過這麼久還沒發的就不補發

function serviceKey(): string {
  try {
    const j = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    const k = j.default ?? Object.values(j)[0];
    if (typeof k === "string" && k) return k;
  } catch (_) { /* ignore */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}
const KEY = serviceKey();
const H = (): Record<string, string> => {
  const h: Record<string, string> = { apikey: KEY, "Content-Type": "application/json" };
  if (KEY.startsWith("eyJ")) h.Authorization = `Bearer ${KEY}`;
  return h;
};
const LOG: string[] = [];
const log = (...a: unknown[]) => { const s = a.map((x) => typeof x === "string" ? x : JSON.stringify(x)).join(" "); LOG.push(s); console.log(s); };

// deno-lint-ignore no-explicit-any
async function sb(method: string, path: string, body?: unknown, prefer = "return=representation"): Promise<any> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method, headers: { ...H(), Prefer: prefer }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30_000) });
  const t = await r.text();
  if (!r.ok) throw new Error(`supabase ${r.status} ${t.slice(0, 160)}`);
  return t ? JSON.parse(t) : null;
}

// deno-lint-ignore no-explicit-any
async function graph(method: string, path: string, params: Record<string, string>): Promise<any> {
  const body = new URLSearchParams({ ...params, access_token: TOKEN });
  const url = method === "GET" ? `${GRAPH}/${path}?${body}` : `${GRAPH}/${path}`;
  const r = await fetch(url, { method, body: method === "GET" ? undefined : body, signal: AbortSignal.timeout(60_000) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(`graph ${r.status} ${JSON.stringify(j.error ?? j).slice(0, 200)}`);
  return j;
}

let PAGE: { id: string; ig?: string } | null = null;
async function page() {
  if (PAGE) return PAGE;
  const j = await graph("GET", "me", { fields: "id,name,instagram_business_account{id,username}" });
  PAGE = { id: j.id, ig: j.instagram_business_account?.id };
  log("粉專", j.name, j.id, "IG", j.instagram_business_account?.username ?? "（未連結）");
  return PAGE;
}

// deno-lint-ignore no-explicit-any
async function threads(method: string, path: string, params: Record<string, string>): Promise<any> {
  const body = new URLSearchParams({ ...params, access_token: TH_TOKEN });
  const url = method === "GET" ? `${THREADS}/${path}?${body}` : `${THREADS}/${path}`;
  const r = await fetch(url, { method, body: method === "GET" ? undefined : body, signal: AbortSignal.timeout(60_000) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(`threads ${r.status} ${JSON.stringify(j.error ?? j).slice(0, 200)}`);
  return j;
}
let TH_ID = "";
async function thUser() {
  if (TH_ID) return TH_ID;
  const j = await threads("GET", "me", { fields: "id,username" });
  log("Threads", j.username, j.id);
  TH_ID = j.id; return TH_ID;
}

// ---------------------------------------------------------------- 文字
const CITY_SHORT = (c: string) => (c || "").replace(/^臺/, "台").replace(/[市縣]$/, "");
const SP = (s: string) => s === "cat" ? { n: "貓咪", t: "尋貓" } : { n: "狗狗", t: "尋狗" };
const tw = (ts: string) => { const d = new Date(new Date(ts).getTime() + 8 * 3600e3); return `${d.getUTCMonth() + 1}/${d.getUTCDate()}`; };
const clip = (s: string, n: number) => { s = String(s ?? "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n) + "…" : s; };
// 不讓電話號碼、Email、LINE ID 出現在貼文（特徵欄位有時候飼主會寫）
const scrub = (s: string) => String(s ?? "").replace(/(\+?886|0)9\d{2}[-\s]?\d{3}[-\s]?\d{3}/g, "").replace(/\b0\d{1,2}[-\s]?\d{6,8}\b/g, "").replace(/[\w.+-]+@[\w-]+\.[\w.]+/g, "").replace(/(line|賴)\s*(id)?\s*[:：]?\s*@?[\w.-]{3,}/gi, "");

const pick = <T,>(a: T[]): T => a[Math.floor(Math.random() * a.length)];
const twTime = (ts: string) => {
  const d = new Date(new Date(ts).getTime() + 8 * 3600e3), h = d.getUTCHours(), m = d.getUTCMinutes();
  const part = h < 5 ? "凌晨" : h < 11 ? "上午" : h < 13 ? "中午" : h < 18 ? "下午" : "晚上";
  const hh = h > 12 ? h - 12 : h;
  return `${d.getUTCMonth() + 1}/${d.getUTCDate()} ${part}${h === 0 && m === 0 ? "" : ` ${hh} 點${m ? m + " 分" : ""}左右`}`;
};
const fmtPhone = (p: string) => { const d = String(p ?? "").replace(/\D/g, "").replace(/^886/, "0"); return /^09\d{8}$/.test(d) ? `${d.slice(0, 4)}-${d.slice(4, 7)}-${d.slice(7)}` : String(p ?? "").trim(); };

// 貼文規則：不用「牠」，用男生／女生；電話單獨一行＋稱呼；說明汪喵回家只是集中力量的網站與初衷；結尾 App Store 搜尋
// where：fb（可放網址）、ig（網址看個人簡介）、th（Threads 不放網址）
// deno-lint-ignore no-explicit-any
function caption(c: any, where: "fb" | "ig" | "th"): string {
  const sp = SP(c.species), city = CITY_SHORT(c.lost_city), area = `${(c.lost_city ?? "").replace(/^臺/, "台")}${c.lost_district ?? ""}`;
  const name = clip(c.name, 12);
  const kid = c.sex === "male" ? "男生" : c.sex === "female" ? "女生" : (c.species === "cat" ? "貓咪" : "狗狗");
  const who = [c.age_text ? clip(c.age_text, 10) : "", c.breed ? clip(c.breed, 12) : "", kid].filter(Boolean).join("的");
  const look = [c.colour ? clip(scrub(c.colour), 20) : "", c.has_chip ? "有晶片" : ""].filter(Boolean).join("、");
  const feat = clip(scrub(c.features || c.collar_desc || ""), 70);
  const place = c.lost_place ? clip(scrub(c.lost_place), 30) : "";
  const phone = c.phone_public && c.contact_phone ? fmtPhone(c.contact_phone) : "";
  const callName = clip(c.contact_name, 10) || `${name}家人`;
  const url = `${SITE}p/${c.id}`;
  const open = pick([
    `${area}，${who}「${name}」走失了，請大家幫忙留意 🙏`,
    `🆘 協尋｜${area}走失的${who}「${name}」`,
    `找${name}！${area}一隻${who}在 ${twTime(c.lost_at)} 走失了`,
    `${name}還沒回家｜${area}・${who}`,
  ]);
  const report = where === "fb" ? `線索可以到汪喵回家回報：${url}` : where === "ig" ? "線索可以到汪喵回家回報（網址在個人簡介）" : "線索也可以到汪喵回家網站回報";
  return [
    open, "",
    `走失時間：${twTime(c.lost_at)}（飼主填寫）`,
    `走失地點：${area}${place ? " " + place : ""}`,
    look ? `外觀：${look}` : null,
    feat ? `特徵：${feat}` : null,
    "",
    pick(["看到請不要追，先拍照、記下時間地點和往哪個方向走。", "看到請不要大聲叫或追，拍照記下地點就好，慢慢跟著更容易找回。"]),
    phone ? `請打給${callName}：` : `請聯絡${callName}：`,
    phone || "（飼主沒有公開電話，請到汪喵回家留言或回報）",
    callName,
    report,
    "",
    "汪喵回家只是幫忙集中力量的網站，完全免費，希望每一隻走失的毛孩都能早點回家。",
    where === "th" ? null : `#汪喵回家 #走失協尋 #${sp.t} #${city}${sp.t}`,
    "App Store 搜尋『汪喵回家』",
  ].filter((x) => x !== null).join("\n");
}

// ---------------------------------------------------------------- IG 照片（IG 只收 4:5 到 1.91:1 的 JPEG，太高的照片補白邊成 4:5）
const okImg = (u: string) => typeof u === "string" && /^https:\/\/nopyhfpaykkiieudvoko\.supabase\.co\/storage\/v1\/object\/public\/photos\/[^\s'"()<>\\]+\.jpe?g$/i.test(u);
async function igImage(caseId: string, url: string): Promise<string> {
  const buf = new Uint8Array(await (await fetch(url, { signal: AbortSignal.timeout(30_000) })).arrayBuffer());
  const { Image } = await import("https://deno.land/x/imagescript@1.3.0/mod.ts");
  // deno-lint-ignore no-explicit-any
  const img: any = await Image.decode(buf);
  const r = img.width / img.height;
  if (r >= 0.8 && r <= 1.91) return url;
  let W = img.width, Hh = img.height;
  if (r < 0.8) W = Math.round(Hh * 0.8); else Hh = Math.round(W / 1.91);
  const bg = new Image(W, Hh); bg.fill(0xFDE3EAFF);
  bg.composite(img, Math.round((W - img.width) / 2), Math.round((Hh - img.height) / 2));
  const jpg = await bg.encodeJPEG(88);
  const path = `social/${caseId}.jpg`;
  const up = await fetch(`${SUPABASE_URL}/storage/v1/object/photos/${path}`, { method: "POST", headers: { ...H(), "Content-Type": "image/jpeg", "x-upsert": "true" }, body: jpg });
  if (!up.ok) throw new Error("upload " + up.status);
  return `${SUPABASE_URL}/storage/v1/object/public/photos/${path}`;
}

// ---------------------------------------------------------------- 新案件
async function runCases() {
  const now = Date.now();
  const rows = await sb("GET", `cases?select=id,name,species,sex,age_text,breed,colour,features,collar_desc,has_chip,lost_at,lost_city,lost_district,lost_place,photos,created_at,owner_id,contact_name,contact_phone,phone_public` +
    `&status=eq.searching&social_ok=is.true&social_posted_at=is.null&hidden=not.is.true&or=(source.is.null,source.eq.site)` +
    `&created_at=lt.${new Date(now - WAIT_MIN * 60e3).toISOString()}&created_at=gt.${new Date(now - MAX_AGE_H * 3600e3).toISOString()}` +
    `&order=created_at.asc&limit=${PER_RUN * 3}`);
  // deno-lint-ignore no-explicit-any
  const admins = new Set(((await sb("GET", "profiles?select=id&is_admin=is.true")) ?? []).map((x: { id: string }) => x.id));
  // 同一支電話 7 天內已經發過就不再發（避免重複登記洗版）
  const recent = await sb("GET", `cases?select=contact_phone&social_post=not.is.null&social_posted_at=gt.${new Date(now - 7 * 864e5).toISOString()}&limit=500`) ?? [];
  const seenPh = new Set(recent.map((x: { contact_phone: string }) => String(x.contact_phone ?? "").replace(/\D/g, "")).filter(Boolean));
  // deno-lint-ignore no-explicit-any
  const todo = (rows ?? []).filter((c: any) => {
    if (!(c.photos ?? []).some(okImg) || !String(c.name ?? "").trim() || !c.lost_city) return false;
    if (c.owner_id && admins.has(c.owner_id)) return false;                       // 站長自己登記的：手動發
    if (now - Date.parse(c.lost_at) > 30 * 864e5) return false;                   // 走失超過 30 天才登記的不自動發
    const ph = String(c.contact_phone ?? "").replace(/\D/g, "");
    if (ph && seenPh.has(ph)) return false;
    if (ph) seenPh.add(ph);
    return true;
  }).slice(0, PER_RUN);
  log("待發案件", todo.length);
  if (!todo.length) return;
  const pg = TOKEN ? await page() : null;
  for (const c of todo) {
    const photo = (c.photos as string[]).find(okImg)!;
    // 先標記（避免下一輪重複發）；失敗時記錄原因
    await sb("PATCH", `cases?id=eq.${c.id}&social_posted_at=is.null`, { social_posted_at: new Date().toISOString() }, "return=minimal");
    // deno-lint-ignore no-explicit-any
    const out: any = {};
    if (pg) {
      try { const j = await graph("POST", `${pg.id}/photos`, { url: photo, caption: caption(c, "fb") }); out.fb = j.post_id ?? j.id; }
      catch (e) { out.fb_err = String(e).slice(0, 200); }
    }
    if (pg?.ig) {
      try {
        const img = await igImage(c.id, photo);
        const m = await graph("POST", `${pg.ig}/media`, { image_url: img, caption: caption(c, "ig") });
        // IG 要等照片處理完才能發佈
        for (let i = 0; i < 10; i++) {
          const s = await graph("GET", m.id, { fields: "status_code" });
          if (s.status_code === "FINISHED") break;
          if (s.status_code === "ERROR") throw new Error("ig media error");
          await new Promise((r) => setTimeout(r, 3000));
        }
        const p = await graph("POST", `${pg.ig}/media_publish`, { creation_id: m.id });
        out.ig = p.id;
      } catch (e) { out.ig_err = String(e).slice(0, 200); }
    }
    if (TH_TOKEN) {
      try {
        const uid = await thUser();
        const m = await threads("POST", `${uid}/threads`, { media_type: "IMAGE", image_url: photo, text: caption(c, "th").slice(0, 500), topic_tag: c.species === "cat" ? "貓咪走失" : "狗狗走失" });
        for (let i = 0; i < 10; i++) {
          const st = await threads("GET", m.id, { fields: "status" });
          if (st.status === "FINISHED") break;
          if (st.status === "ERROR") throw new Error("threads media error");
          await new Promise((r) => setTimeout(r, 3000));
        }
        const p = await threads("POST", `${uid}/threads_publish`, { creation_id: m.id });
        out.th = p.id;
      } catch (e) { out.th_err = String(e).slice(0, 200); }
    }
    log("案件", c.id, out);
    await sb("PATCH", `cases?id=eq.${c.id}`, { social_post: out }, "return=minimal");
  }
}

// ---------------------------------------------------------------- 每週找回
async function runWeekly() {
  const since = new Date(Date.now() - 7 * 864e5).toISOString();
  const found = await sb("GET", `cases?select=id,name,species,lost_city,lost_district,found_at&status=eq.found&found_at=gte.${since}&hidden=not.is.true&or=(source.is.null,source.eq.site)&order=found_at.desc&limit=10`) ?? [];
  const fresh = await sb("GET", `cases?select=id&created_at=gte.${since}&hidden=not.is.true&or=(source.is.null,source.eq.site)&limit=500`) ?? [];
  log("本週找回", found.length, "本週新登記", fresh.length);
  if (!found.length && !fresh.length) { log("本週沒有資料，不發文"); return; }
  const lines: string[] = [];
  if (found.length) {
    lines.push(`🎉 本週有 ${found.length} 隻毛孩回家了！`, "");
    // deno-lint-ignore no-explicit-any
    for (const c of found) lines.push(`🏠 ${clip(c.name, 12)}（${c.lost_city ?? ""}${c.lost_district ?? ""}的${SP(c.species).n}）`);
    lines.push("", "謝謝每一位幫忙分享、回報目擊的你 💛");
  } else {
    lines.push("💪 本週還沒有毛孩回家的消息，大家繼續幫忙留意。");
  }
  if (fresh.length) lines.push("", `這週有 ${fresh.length} 隻毛孩在汪喵回家登記協尋，請幫忙看看你家附近有沒有毛孩們：`, `${SITE}l/`);
  lines.push("", "毛孩走失了？免費登記協尋 👉 " + SITE, "#汪喵回家 #走失協尋 #尋狗 #尋貓 #毛孩回家");
  if (!TOKEN) { log("沒有 FB_PAGE_TOKEN，每週貼文略過"); return; }
  const pg = await page();
  const j = await graph("POST", `${pg.id}/feed`, { message: lines.join("\n"), link: found.length ? SITE : `${SITE}l/` });
  log("每週貼文", j.id);
}

// ---------------------------------------------------------------- 入口
async function secretOk(s: string) {
  if (!s) return false;
  try { return (await sb("POST", "rpc/daily_run_secret_ok", { p: s })) === true; } catch (_) { return false; }
}
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (!(await secretOk(req.headers.get("x-run-secret") ?? ""))) return new Response("forbidden", { status: 403 });
  const { mode = "cases" } = await req.json().catch(() => ({}));
  if (mode === "preview") { const r = await sb("GET", `cases?select=*&status=eq.searching&hidden=not.is.true&order=created_at.desc&limit=3`); for (const c of r ?? []) { log(caption(c, "fb")); log("--- threads ---"); log(caption(c, "th")); log("======"); } return Response.json({ ok: true, log: LOG }); }
  if (!TOKEN && !TH_TOKEN) { log("尚未設定 FB_PAGE_TOKEN / THREADS_TOKEN，略過"); return Response.json({ ok: false, log: LOG }); }
  try {
    if (mode === "probe") { if (TOKEN) await page(); if (TH_TOKEN) await thUser(); }
    else if (mode === "weekly") await runWeekly();
    else await runCases();
    return Response.json({ ok: true, log: LOG });
  } catch (e) {
    log("錯誤", String(e).slice(0, 300));
    return Response.json({ ok: false, log: LOG }, { status: 500 });
  }
});

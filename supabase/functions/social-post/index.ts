// 汪喵回家 — 自動發粉專貼文 v1.0.0
//   cases  ：每 30 分鐘。新登記、有照片、飼主同意分享的協尋案件 → 發到 FB 粉專（照片＋說明）與 IG（同一張照片）
//   weekly ：每週日晚上。「本週找回」整理 → 發到 FB 粉專
//   probe  ：只檢查權杖能不能用（不發文）
//
// 網址：POST https://<project>.supabase.co/functions/v1/social-post   body：{"mode":"cases"|"weekly"|"probe"}
// header：x-run-secret（和 daily-run 共用 Vault 裡的 daily_run_secret；排程 SQL 會自動帶上）
// Secrets：FB_PAGE_TOKEN（粉專的長效存取權杖，由站長自己貼到 Supabase → Edge Functions → Secrets）
// 部署：.github/workflows/fn-deploy.yml（關閉 Verify JWT）

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
const SITE = "https://wangmiaotw.com/";
const GRAPH = "https://graph.facebook.com/v21.0";
const TOKEN = (Deno.env.get("FB_PAGE_TOKEN") ?? "").trim();
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

// ---------------------------------------------------------------- 文字
const CITY_SHORT = (c: string) => (c || "").replace(/^臺/, "台").replace(/[市縣]$/, "");
const SP = (s: string) => s === "cat" ? { n: "貓咪", t: "尋貓" } : { n: "狗狗", t: "尋狗" };
const tw = (ts: string) => { const d = new Date(new Date(ts).getTime() + 8 * 3600e3); return `${d.getUTCMonth() + 1}/${d.getUTCDate()}`; };
const clip = (s: string, n: number) => { s = String(s ?? "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n) + "…" : s; };
// 不讓電話號碼、Email、LINE ID 出現在貼文（特徵欄位有時候飼主會寫）
const scrub = (s: string) => String(s ?? "").replace(/(\+?886|0)9\d{2}[-\s]?\d{3}[-\s]?\d{3}/g, "").replace(/\b0\d{1,2}[-\s]?\d{6,8}\b/g, "").replace(/[\w.+-]+@[\w-]+\.[\w.]+/g, "").replace(/(line|賴)\s*(id)?\s*[:：]?\s*@?[\w.-]{3,}/gi, "");

// deno-lint-ignore no-explicit-any
function caption(c: any, forIG: boolean): string {
  const sp = SP(c.species), city = CITY_SHORT(c.lost_city), where = `${c.lost_city ?? ""}${c.lost_district ?? ""}`;
  const look = [c.breed, c.colour].filter(Boolean).join("・");
  const feat = clip(scrub(c.features || c.collar_desc || ""), 70);
  const url = `${SITE}p/${c.id}`;
  return [
    `🆘 協尋｜${where} 走失${sp.n}「${clip(c.name, 12)}」`,
    "",
    `📅 走失日期：${tw(c.lost_at)}`,
    `📍 地點：${where}${c.lost_place ? " " + clip(scrub(c.lost_place), 30) : ""}`,
    look ? `🐾 外觀：${look}` : null,
    feat ? `🔎 特徵：${feat}` : null,
    c.has_chip ? "💡 有晶片" : null,
    "",
    "看到牠請不要追，拍照並記下時間、地點和牠往哪走，再回報給飼主。",
    forIG ? `👉 回報目擊：個人簡介的連結，搜尋「${clip(c.name, 12)}」` : `👉 回報目擊：${url}`,
    "",
    `請幫忙分享，讓${clip(c.name, 12)}早點回家 🙏`,
    `#汪喵回家 #走失協尋 #${sp.t} #${city}${sp.t} #${city}`,
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
  const rows = await sb("GET", `cases?select=id,name,species,breed,colour,features,collar_desc,has_chip,lost_at,lost_city,lost_district,lost_place,photos,created_at` +
    `&status=eq.searching&social_ok=is.true&social_posted_at=is.null&hidden=not.is.true&or=(source.is.null,source.eq.site)` +
    `&created_at=lt.${new Date(now - WAIT_MIN * 60e3).toISOString()}&created_at=gt.${new Date(now - MAX_AGE_H * 3600e3).toISOString()}` +
    `&order=created_at.asc&limit=${PER_RUN * 3}`);
  // deno-lint-ignore no-explicit-any
  const todo = (rows ?? []).filter((c: any) => (c.photos ?? []).some(okImg)).slice(0, PER_RUN);
  log("待發案件", todo.length);
  if (!todo.length) return;
  const pg = await page();
  for (const c of todo) {
    const photo = (c.photos as string[]).find(okImg)!;
    // 先標記（避免下一輪重複發）；失敗時記錄原因
    await sb("PATCH", `cases?id=eq.${c.id}&social_posted_at=is.null`, { social_posted_at: new Date().toISOString() }, "return=minimal");
    // deno-lint-ignore no-explicit-any
    const out: any = {};
    try { const j = await graph("POST", `${pg.id}/photos`, { url: photo, caption: caption(c, false) }); out.fb = j.post_id ?? j.id; }
    catch (e) { out.fb_err = String(e).slice(0, 200); }
    if (pg.ig) {
      try {
        const img = await igImage(c.id, photo);
        const m = await graph("POST", `${pg.ig}/media`, { image_url: img, caption: caption(c, true) });
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
  if (fresh.length) lines.push("", `這週有 ${fresh.length} 隻毛孩在汪喵回家登記協尋，請幫忙看看你家附近有沒有牠們：`, `${SITE}l/`);
  lines.push("", "毛孩走失了？免費登記協尋 👉 " + SITE, "#汪喵回家 #走失協尋 #尋狗 #尋貓 #毛孩回家");
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
  if (!TOKEN) { log("尚未設定 FB_PAGE_TOKEN，略過"); return Response.json({ ok: false, log: LOG }); }
  try {
    if (mode === "probe") await page();
    else if (mode === "weekly") await runWeekly();
    else await runCases();
    return Response.json({ ok: true, log: LOG });
  } catch (e) {
    log("錯誤", String(e).slice(0, 300));
    return Response.json({ ok: false, log: LOG }, { status: 500 });
  }
});

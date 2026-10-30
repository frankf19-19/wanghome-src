// 汪喵回家 — 電子毛孩 AI 畫圖 v1.1（優先用 Cloudflare 免費 AI；沒設定才用 Google Gemini）
// 網址：POST https://<project>.supabase.co/functions/v1/buddy-art   （需要登入：保留「Verify JWT」開啟）
//   {"pose":"ok|happy|sleep|eat|sad|walk","sp":"dog|cat","photo":"<jpeg base64>","ref":"<第一張畫好的圖 base64，可省略>"}
//   回傳 {"image":"<base64>","mime":"image/png","left":<今天還能畫幾張>}
// 照會員自己毛孩的照片，用 Google Gemini 畫成可愛的 Q 版毛孩（同一隻毛孩畫 6 個動作）。
// 費用控制：每位會員 24 小時內最多 BUDDY_ART_PER_USER 張（預設 14 張 ≈ 畫兩次），全站每天最多 BUDDY_ART_DAILY_CAP 張（預設 300）。
// Secrets（Supabase → Edge Functions → Secrets）：
//   免費方案：CF_ACCOUNT_ID、CF_AI_TOKEN（Cloudflare Workers AI，每天免費額度約可畫 80 張）
//   付費方案（可省略）：GEMINI_API_KEY、GEMINI_IMAGE_MODEL
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

const GAPI = "https://generativelanguage.googleapis.com/v1beta";
let modelCache = "";
async function pickModel(key: string): Promise<string> {
  const env = (Deno.env.get("GEMINI_IMAGE_MODEL") ?? "").trim();
  if (env) return env.replace(/^models\//, "");
  if (modelCache) return modelCache;
  const r = await fetch(`${GAPI}/models?pageSize=1000`, { headers: { "x-goog-api-key": key } });
  if (!r.ok) throw new Error("models " + r.status);
  const j = await r.json();
  const names: string[] = (j.models ?? [])
    .filter((m: any) => (m.supportedGenerationMethods ?? []).includes("generateContent"))
    .map((m: any) => String(m.name).replace(/^models\//, ""))
    .filter((n: string) => /image/.test(n) && !/imagen/.test(n));
  // 偏好便宜又快的 flash 系列，新版優先；pro 太貴不用
  const pref = ["nano-banana-2.1", "3.1-flash-image", "flash-image", "nano-banana"];
  let pick = "";
  for (const p of pref) { pick = names.find((n) => n.includes(p) && !/pro/.test(n) && !/preview/.test(n)) ?? names.find((n) => n.includes(p) && !/pro/.test(n)) ?? ""; if (pick) break; }
  if (!pick) pick = names.find((n) => !/pro/.test(n)) ?? "";
  if (!pick) throw new Error("no image model");
  modelCache = pick;
  return pick;
}

const STYLE =
  "Art style: an adorable, high-quality chibi 3D cartoon figurine (like a premium collectible toy / animated movie character): soft rounded shapes, slightly oversized head, big shiny expressive eyes with catchlights, soft fluffy fur texture, gentle studio lighting. " +
  "It must clearly look like THIS specific pet: keep its exact fur colours, colour distribution and markings (where the darker and lighter patches are), ear shape and ear position, muzzle length, face shape, eye colour, nose colour and fur length. Do not add markings it does not have. " +
  "Show the whole body, centered, with a small empty margin around it. Solid flat pure green chroma-key background (#00FF00) filling the whole image, no floor, no shadow, no green reflections on the fur, no text, no frame, no collar, no clothes, no other animals or objects unless asked.";
const POSES: Record<string, (sp: string) => string> = {
  ok: (sp) => `Pose: sitting upright, facing the viewer, calm and friendly, ${sp === "cat" ? "mouth closed" : "gentle closed-mouth smile"}.`,
  happy: (sp) => `Pose: sitting upright, facing the viewer, very happy and excited, ${sp === "cat" ? "eyes happily squinted into arcs, small open-mouth smile" : "mouth wide open in a big smile with the tongue out, eyes bright"}.`,
  sleep: () => "Pose: curled up lying down on its belly, fast asleep, eyes closed, peaceful, seen from the front, body wider than tall.",
  eat: () => "Pose: crouching facing the viewer, head lowered, happily eating kibble from a small round red food bowl placed in front of it (the bowl is the only extra object).",
  sad: () => "Pose: lying on its belly facing the viewer, chin resting on its front paws, sad droopy eyes looking up, a little lonely.",
  walk: () => "Pose: full side view (profile) walking toward the RIGHT side of the image, mid-stride with all four legs visible, head and nose pointing right, tail behind on the left.",
};

function b64ok(s: unknown, max: number): s is string {
  return typeof s === "string" && s.length > 100 && s.length < max && /^[A-Za-z0-9+/=]+$/.test(s.slice(0, 200));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const key = Deno.env.get("GEMINI_API_KEY") ?? "";
  const cfAcc = (Deno.env.get("CF_ACCOUNT_ID") ?? "").trim(), cfTok = (Deno.env.get("CF_AI_TOKEN") ?? "").trim();
  const useCF = !!(cfAcc && cfTok);
  if (!useCF && !key) return json({ error: "AI 畫圖還沒開通", code: "nokey" }, 503);

  const url = Deno.env.get("SUPABASE_URL")!;
  const auth = req.headers.get("Authorization") ?? "";
  const admin = createClient(url, serviceKey(), { auth: { persistSession: false } });
  const { data: u, error: ue } = await admin.auth.getUser(auth.replace(/^Bearer\s+/i, ""));
  if (ue || !u?.user) return json({ error: "請先登入" }, 401);
  const uid = u.user.id;

  let body: any;
  try { body = await req.json(); } catch (_) { return json({ error: "格式錯誤" }, 400); }
  const pose = String(body.pose ?? "");
  const sp = body.sp === "cat" ? "cat" : "dog";
  if (!POSES[pose]) return json({ error: "pose" }, 400);
  if (!b64ok(body.photo, 1_600_000)) return json({ error: "照片太大或格式不對" }, 400);
  const ref = b64ok(body.ref, 2_400_000) ? body.ref : null;

  // 次數限制
  const perUser = Number(Deno.env.get("BUDDY_ART_PER_USER") ?? 14), cap = Number(Deno.env.get("BUDDY_ART_DAILY_CAP") ?? (useCF ? 80 : 300));
  const since = new Date(Date.now() - 864e5).toISOString();
  const [{ count: mine }, { count: all }] = await Promise.all([
    admin.from("buddy_art_log").select("id", { count: "exact", head: true }).eq("user_id", uid).gte("created_at", since),
    admin.from("buddy_art_log").select("id", { count: "exact", head: true }).gte("created_at", since),
  ]);
  if ((mine ?? 0) >= perUser) return json({ error: "今天畫太多次了，明天再試試", code: "limit", left: 0 }, 429);
  if ((all ?? 0) >= cap) return json({ error: "今天全站的 AI 畫圖次數用完了，明天再試試", code: "cap" }, 429);

  const animal = sp === "cat" ? "cat" : "dog";
  if (useCF) {
    const b2u = (b: string) => Uint8Array.from(atob(b), (c) => c.charCodeAt(0));
    const fd = new FormData();
    const prompt = ref
      ? `Image 0 is a finished cute character design of a ${animal}. Image 1 is a real photo of the same ${animal}. Draw exactly the same character as image 0 (same design, colours, markings, proportions and art style) in a new pose. ${POSES[pose](sp)} ${STYLE}`
      : `Image 0 is a real photo of my ${animal}. Turn this exact ${animal} into a cute character. ${POSES[pose](sp)} ${STYLE}`;
    fd.append("prompt", prompt);
    if (ref) { fd.append("input_image_0", new Blob([b2u(ref)], { type: "image/jpeg" }), "ref.jpg"); fd.append("input_image_1", new Blob([b2u(body.photo)], { type: "image/jpeg" }), "photo.jpg"); }
    else fd.append("input_image_0", new Blob([b2u(body.photo)], { type: "image/jpeg" }), "photo.jpg");
    fd.append("width", "768"); fd.append("height", "768");
    const CFM = Deno.env.get("CF_IMAGE_MODEL") ?? "@cf/black-forest-labs/flux-2-klein-4b";
    let out = "", why = "", st = 0;
    for (let attempt = 0; attempt < 2 && !out; attempt++) {
      const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${cfAcc}/ai/run/${CFM}`, { method: "POST", headers: { Authorization: `Bearer ${cfTok}` }, body: fd });
      st = r.status; const t = await r.text();
      if (!r.ok) { why = `${r.status} ${t.slice(0, 300)}`; console.error("cf", CFM, why); if (r.status !== 500 && r.status !== 502 && r.status !== 503) break; continue; }
      try { const j = JSON.parse(t); out = j.result?.image ?? j.image ?? ""; if (!out) why = "no image: " + t.slice(0, 200); } catch (e) { why = String(e); }
    }
    if (!out) {
      console.error("buddy-art fail", CFM, why);
      const quota = st === 429 || /neuron|quota|limit|exceed/i.test(why);
      return json(quota ? { error: "今天的免費 AI 畫圖次數用完了，明天再來試試", code: "cap" } : { error: "這次沒畫出來，再試一次看看", detail: why.slice(0, 200) }, quota ? 429 : 502);
    }
    const mime = out.startsWith("/9j/") ? "image/jpeg" : out.startsWith("UklG") ? "image/webp" : "image/png";
    await admin.from("buddy_art_log").insert({ user_id: uid, pose, model: CFM });
    return json({ image: out, mime, left: Math.max(0, perUser - (mine ?? 0) - 1), model: CFM });
  }
  const parts: any[] = [];
  if (ref) {
    parts.push({ text: `Image 1 is the finished character design of this ${animal}. Image 2 is the real photo of the ${animal} for reference. Draw the SAME character as image 1 (identical design, colours, markings, proportions and art style) in a new pose. ${POSES[pose](sp)} ${STYLE}` });
    parts.push({ inline_data: { mime_type: "image/jpeg", data: ref } });
    parts.push({ inline_data: { mime_type: "image/jpeg", data: body.photo } });
  } else {
    parts.push({ text: `This is a photo of my ${animal}. Turn it into a cute character. ${POSES[pose](sp)} ${STYLE}` });
    parts.push({ inline_data: { mime_type: "image/jpeg", data: body.photo } });
  }

  let model = "";
  try { model = await pickModel(key); } catch (e) { console.error("pickModel", e); return json({ error: "AI 服務暫時連不上，請稍後再試" }, 502); }
  let img: { data: string; mime: string } | null = null, why = "";
  for (let attempt = 0; attempt < 2 && !img; attempt++) {
    const r = await fetch(`${GAPI}/models/${model}:generateContent`, {
      method: "POST",
      headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ role: "user", parts }],
        generationConfig: { responseModalities: ["IMAGE"], imageConfig: { aspectRatio: "1:1" } },
      }),
    });
    const t = await r.text();
    if (!r.ok) { why = `${r.status} ${t.slice(0, 300)}`; console.error("gemini", model, why); if (r.status === 400 || r.status === 403 || r.status === 404) break; continue; }
    try {
      const j = JSON.parse(t);
      for (const c of j.candidates ?? []) for (const p of c.content?.parts ?? []) {
        const d = p.inlineData ?? p.inline_data;
        if (d?.data) { img = { data: d.data, mime: d.mimeType ?? d.mime_type ?? "image/png" }; break; }
      }
      if (!img) why = "no image: " + t.slice(0, 300);
    } catch (e) { why = String(e); }
  }
  if (!img) { console.error("buddy-art fail", model, why); const quota = /^429/.test(why); return json(quota ? { error: "AI 畫圖的額度不足，請稍後再試", code: "cap" } : { error: "這次沒畫出來，再試一次看看", detail: why.slice(0, 200) }, quota ? 429 : 502); }

  await admin.from("buddy_art_log").insert({ user_id: uid, pose, model });
  return json({ image: img.data, mime: img.mime, left: Math.max(0, perUser - (mine ?? 0) - 1), model });
});

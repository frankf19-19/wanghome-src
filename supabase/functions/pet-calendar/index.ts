// 汪喵回家 — 毛孩健康提醒日曆（.ics 訂閱）v1.8.0
// 網址：https://<project>.supabase.co/functions/v1/pet-calendar?t=<calendar_token>
// 日曆 App 無法帶登入資訊，所以本函式需關閉 JWT 驗證；以 profiles.calendar_token 辨識使用者。
import { createClient } from "jsr:@supabase/supabase-js@2";

const SITE = "https://frankf19-19.github.io/wanghome/";
const KIND: Record<string, string> = {
  vet: "回診", vaccine: "疫苗", deworm: "驅蟲／除蚤", med: "用藥",
  surgery: "手術", weight: "量體重", grooming: "美容洗澡", other: "提醒",
};

function esc(s: string) {
  return String(s ?? "").replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}
// RFC 5545：每行最多 75 bytes，超過要折行（續行以空白開頭）
function fold(line: string) {
  const enc = new TextEncoder();
  if (enc.encode(line).length <= 75) return line;
  const out: string[] = [];
  let cur = "";
  for (const ch of line) {
    if (enc.encode(cur + ch).length > (out.length ? 74 : 75)) { out.push(cur); cur = ch; }
    else cur += ch;
  }
  out.push(cur);
  return out.join("\r\n ");
}
const ymd = (d: string) => d.replaceAll("-", "");
function nextDay(d: string) {
  const t = new Date(d + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + 1);
  return t.toISOString().slice(0, 10).replaceAll("-", "");
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const t = url.searchParams.get("t") ?? "";
  if (!/^[0-9a-f-]{36}$/i.test(t)) return new Response("Not found", { status: 404 });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: prof } = await sb.from("profiles").select("id").eq("calendar_token", t).maybeSingle();
  if (!prof) return new Response("Not found", { status: 404 });

  const since = new Date(Date.now() - 90 * 86400000).toISOString().slice(0, 10);
  const { data: recs, error } = await sb.from("pet_records")
    .select("id,title,kind,clinic,next_due,updated_at,pet_id,pets(name)")
    .eq("owner_id", prof.id).eq("done", false).not("next_due", "is", null).gte("next_due", since)
    .order("next_due").limit(500);
  if (error) return new Response("Error", { status: 500 });

  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//WangMiao Home//Pet Health//ZH-TW", "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH", "X-WR-CALNAME:汪喵回家・毛孩健康提醒", "X-WR-TIMEZONE:Asia/Taipei",
    "REFRESH-INTERVAL;VALUE=DURATION:PT6H", "X-PUBLISHED-TTL:PT6H",
  ];
  for (const r of recs ?? []) {
    // deno-lint-ignore no-explicit-any
    const pet = (r as any).pets?.name ?? "毛孩";
    const kind = KIND[r.kind] ?? "提醒";
    const desc = [`${pet}的${kind}：${r.title}`, r.clinic ? `醫院：${r.clinic}` : "", `完成後到網站標記已完成：${SITE}#/pet/${r.pet_id}`].filter(Boolean).join("\n");
    lines.push(
      "BEGIN:VEVENT",
      `UID:${r.id}@wanghome`,
      `DTSTAMP:${stamp}`,
      `DTSTART;VALUE=DATE:${ymd(r.next_due)}`,
      `DTEND;VALUE=DATE:${nextDay(r.next_due)}`,
      `SUMMARY:${esc(`🐾 ${pet}｜${r.title}`)}`,
      `DESCRIPTION:${esc(desc)}`,
      ...(r.clinic ? [`LOCATION:${esc(r.clinic)}`] : []),
      `URL:${SITE}#/pet/${r.pet_id}`,
      "TRANSP:TRANSPARENT",
      "BEGIN:VALARM", "ACTION:DISPLAY", `DESCRIPTION:${esc(`${pet}明天${kind}：${r.title}`)}`, "TRIGGER:-PT15H", "END:VALARM",
      "END:VEVENT",
    );
  }
  lines.push("END:VCALENDAR");
  const body = lines.map(fold).join("\r\n") + "\r\n";
  return new Response(body, {
    headers: {
      "content-type": "text/calendar; charset=utf-8",
      "content-disposition": 'inline; filename="wangmiao-pets.ics"',
      "cache-control": "private, max-age=900",
    },
  });
});

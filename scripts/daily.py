#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
汪回家 WangHome — 每日自動化腳本  v1.0.0

做三件事：
  1. 抓農業部「動物認領養」開放資料，和協尋中的案件比對（縣市/毛色/體型/性別/日期），
     寫入 shelter_matches。
  2. 把「未通知」的目擊回報與收容所比對，寄 Email 給飼主。
  3. 對 Supabase 做一次查詢（保活，免費專案 7 天沒流量會暫停）。

需要的環境變數（放在 GitHub Secrets）：
  SUPABASE_URL              例 https://xxxx.supabase.co
  SUPABASE_SERVICE_KEY      Project Settings → API → service_role（絕不可放到前端）
  SITE_URL                  例 https://你的帳號.github.io/wanghome/
  GMAIL_USER                寄信用 Gmail 帳號（選填，不填就不寄信）
  GMAIL_APP_PASSWORD        Gmail 應用程式密碼（16 碼）
  MOA_API_URL               （選填）覆蓋農業部 API 網址
"""
import os, sys, json, smtplib, datetime as dt, urllib.request, urllib.parse, re
from email.mime.text import MIMEText
from email.header import Header

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SERVICE_KEY  = os.environ.get("SUPABASE_SERVICE_KEY", "")
SITE_URL     = os.environ.get("SITE_URL", "").rstrip("/") + "/"
GMAIL_USER   = os.environ.get("GMAIL_USER", "")
GMAIL_PASS   = os.environ.get("GMAIL_APP_PASSWORD", "")
SITE_NAME    = os.environ.get("SITE_NAME", "汪回家")
MOA_API_URL  = os.environ.get("MOA_API_URL") or \
    "https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=QcbUEzN6E6DL"
UA = "WangHome/1.0 (+lost-dog-matcher)"

if not SUPABASE_URL or not SERVICE_KEY:
    print("缺少 SUPABASE_URL / SUPABASE_SERVICE_KEY"); sys.exit(1)

# ---------------------------------------------------------------- Supabase REST
def sb(method, path, body=None, params=None, prefer=None):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    if params: url += "?" + urllib.parse.urlencode(params, safe=",.*()")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("apikey", SERVICE_KEY)
    req.add_header("Authorization", f"Bearer {SERVICE_KEY}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Prefer", prefer or "return=representation")
    with urllib.request.urlopen(req, timeout=60) as r:
        t = r.read().decode()
        return json.loads(t) if t else None

# ---------------------------------------------------------------- 農業部資料
def fetch_moa():
    req = urllib.request.Request(MOA_API_URL, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read().decode("utf-8-sig")
    data = json.loads(raw)
    if isinstance(data, dict):  # 有些版本包在 {"data":[...]} 裡
        for k in ("data", "result", "records"):
            if isinstance(data.get(k), list): data = data[k]; break
    print(f"農業部資料筆數：{len(data)}")
    return data

CITY_ALIASES = {"台北市":"臺北市","台中市":"臺中市","台南市":"臺南市","台東縣":"臺東縣"}
def norm_city(s):
    s = (s or "").strip()
    return CITY_ALIASES.get(s, s)

COLOUR_GROUPS = {
    "黑": ["黑"], "白": ["白"], "黃": ["黃","米","淺棕","卡其","金"], "棕": ["棕","咖啡","褐","茶"],
    "虎斑": ["虎斑","斑"], "灰": ["灰","銀"], "花": ["花","三色","黑白","黃白","雙色"], "紅": ["紅","橘"],
}
def colour_tokens(s):
    s = s or ""
    out = set()
    for g, kws in COLOUR_GROUPS.items():
        if any(k in s for k in kws): out.add(g)
    return out

SIZE_MAP = {"small":"SMALL","medium":"MEDIUM","large":"BIG"}
SEX_MAP  = {"male":"M","female":"F"}

def score(case, a):
    """粗略相似度 0~100，只比對狗。"""
    if (a.get("animal_kind") or "") != "狗": return -1
    s = 0
    # 縣市：拾獲地或收容所地址
    c = norm_city(case["lost_city"])
    place = norm_city(a.get("animal_foundplace") or "") + norm_city(a.get("shelter_address") or "") + norm_city(a.get("animal_place") or "")
    same_city = c and c in place
    if not same_city: return -1          # 跨縣市先不比對，避免雜訊
    s += 30
    # 拾獲時間必須在走失之後（用 animal_createtime / opendate）
    lost_dt = case["lost_at"][:10]
    found_dt = (a.get("animal_createtime") or a.get("animal_opendate") or "")[:10].replace("/", "-")
    if found_dt and found_dt < lost_dt: return -1
    s += 10
    # 毛色
    ct = colour_tokens(case.get("colour")); at = colour_tokens(a.get("animal_colour"))
    if ct and at:
        s += 25 if ct & at else -15
    # 體型
    if case.get("size") and a.get("animal_bodytype"):
        s += 15 if SIZE_MAP.get(case["size"]) == a["animal_bodytype"] else -10
    # 性別
    if case.get("sex") in SEX_MAP and a.get("animal_sex") in ("M","F"):
        s += 15 if SEX_MAP[case["sex"]] == a["animal_sex"] else -20
    # 區域關鍵字
    d = case.get("lost_district") or ""
    if d and d in place: s += 15
    return max(0, min(100, s))

def run_matching():
    cases = sb("GET", "cases", params={"select": "id,name,lost_city,lost_district,lost_at,colour,size,sex,contact_email", "status": "eq.searching"})
    if not cases: print("沒有協尋中案件"); return
    try:
        animals = fetch_moa()
    except Exception as e:
        print("抓取農業部資料失敗：", e); return
    existing = sb("GET", "shelter_matches", params={"select": "case_id,animal_id"}) or []
    seen = {(m["case_id"], str(m["animal_id"])) for m in existing}
    rows = []
    for c in cases:
        for a in animals:
            sc = score(c, a)
            if sc < 45: continue
            aid = str(a.get("animal_id"))
            if (c["id"], aid) in seen: continue
            photo = a.get("album_file") or ""
            rows.append({
                "case_id": c["id"], "animal_id": aid, "animal_subid": a.get("animal_subid"),
                "shelter_name": a.get("shelter_name"), "shelter_tel": a.get("shelter_tel"),
                "shelter_address": a.get("shelter_address"), "found_place": a.get("animal_foundplace"),
                "colour": a.get("animal_colour"), "bodytype": {"SMALL":"小型","MEDIUM":"中型","BIG":"大型"}.get(a.get("animal_bodytype"), a.get("animal_bodytype")),
                "sex": {"M":"公","F":"母"}.get(a.get("animal_sex"), "不明"), "age": {"CHILD":"幼犬","ADULT":"成犬"}.get(a.get("animal_age"), a.get("animal_age")),
                "variety": a.get("animal_Variety") or a.get("animal_variety"),
                "photo_url": photo if photo.startswith("http") else None,
                "open_date": (a.get("animal_opendate") or None), "score": sc,
            })
    if rows:
        sb("POST", "shelter_matches", body=rows, prefer="return=minimal,resolution=ignore-duplicates")
    print(f"新增比對 {len(rows)} 筆")

# ---------------------------------------------------------------- Email
def send_mail(to, subject, body):
    if not (GMAIL_USER and GMAIL_PASS and to): return False
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = Header(subject, "utf-8"); msg["From"] = f"{SITE_NAME} <{GMAIL_USER}>"; msg["To"] = to
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=30) as s:
        s.login(GMAIL_USER, GMAIL_PASS); s.sendmail(GMAIL_USER, [to], msg.as_string())
    return True

def fmt(ts):
    try:
        d = dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(dt.timezone(dt.timedelta(hours=8)))
        return d.strftime("%m/%d %H:%M")
    except Exception: return ts or ""

def run_notifications():
    if not (GMAIL_USER and GMAIL_PASS):
        print("未設定 Gmail，略過通知"); return
    cases = {c["id"]: c for c in (sb("GET", "cases", params={"select": "id,name,contact_email,edit_token"}) or [])}
    # 目擊
    pend = sb("GET", "sightings", params={"select": "*", "notified": "eq.false", "order": "created_at.asc"}) or []
    by_case = {}
    for s in pend: by_case.setdefault(s["case_id"], []).append(s)
    for cid, lst in by_case.items():
        c = cases.get(cid)
        if not c or not c.get("contact_email"): continue
        lines = [f"你的案件「{c['name']}」有 {len(lst)} 筆新的目擊回報：", ""]
        for s in lst:
            lines.append(f"・{fmt(s['seen_at'])}  {s.get('place_text') or '（見地圖）'}  {('往'+s['direction']) if s.get('direction') else ''}")
            if s.get("note"): lines.append(f"  {s['note']}")
            if s.get("lat"): lines.append(f"  地圖 https://www.google.com/maps?q={s['lat']},{s['lng']}")
            if s.get("reporter_contact"): lines.append(f"  回報者聯絡：{s['reporter_contact']}")
            lines.append("")
        lines += ["請到管理頁確認後才會顯示在公開地圖：", f"{SITE_URL}#/manage/{cid}", "（需要你的管理金鑰）", "", f"— {SITE_NAME}"]
        try:
            send_mail(c["contact_email"], f"【{SITE_NAME}】{c['name']} 有新的目擊回報", "\n".join(lines))
            print(f"已通知目擊：{c['name']} x{len(lst)}")
        except Exception as e:
            print("寄信失敗：", e); continue
        sb("PATCH", "sightings", body={"notified": True}, params={"id": "in.(" + ",".join(s["id"] for s in lst) + ")"}, prefer="return=minimal")
    # 收容所比對
    pend = sb("GET", "shelter_matches", params={"select": "*", "notified": "eq.false", "order": "score.desc"}) or []
    by_case = {}
    for m in pend: by_case.setdefault(m["case_id"], []).append(m)
    for cid, lst in by_case.items():
        c = cases.get(cid)
        if not c or not c.get("contact_email"): continue
        lines = [f"系統在收容所資料中找到 {len(lst)} 筆與「{c['name']}」疑似相符的狗狗，請盡快親自確認：", ""]
        for m in lst[:10]:
            lines.append(f"・{m.get('shelter_name')}  相似 {m['score']}  {m.get('sex','')} {m.get('bodytype','')} {m.get('colour','')}")
            lines.append(f"  拾獲地：{m.get('found_place') or '未註明'}  電話：{m.get('shelter_tel') or ''}")
            if m.get("photo_url"): lines.append(f"  照片：{m['photo_url']}")
            lines.append("")
        lines += ["這只是粗略比對，請打電話到收容所提供晶片號碼核對，或親自到所比對。", f"案件頁：{SITE_URL}#/case/{cid}", "", f"— {SITE_NAME}"]
        try:
            send_mail(c["contact_email"], f"【{SITE_NAME}】收容所有疑似 {c['name']} 的狗狗", "\n".join(lines))
            print(f"已通知比對：{c['name']} x{len(lst)}")
        except Exception as e:
            print("寄信失敗：", e); continue
        sb("PATCH", "shelter_matches", body={"notified": True}, params={"id": "in.(" + ",".join(m["id"] for m in lst) + ")"}, prefer="return=minimal")

# ---------------------------------------------------------------- main
if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    print("WangHome daily v1.0.0 mode =", mode, dt.datetime.now(dt.timezone.utc).isoformat())
    if mode in ("all", "match"): run_matching()
    if mode in ("all", "notify"): run_notifications()
    n = sb("GET", "cases", params={"select": "id", "limit": "1"})
    print("保活 OK", "有資料" if n else "空")

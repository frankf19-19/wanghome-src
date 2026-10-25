#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
汪喵回家 WangHome — 每日自動化腳本  v1.5.0

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
import os, sys, json, smtplib, datetime as dt, urllib.request, urllib.parse, urllib.error, re
from email.mime.text import MIMEText
from email.header import Header

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SERVICE_KEY  = os.environ.get("SUPABASE_SERVICE_KEY", "").strip().strip('"').strip("'")
SITE_URL     = os.environ.get("SITE_URL", "").rstrip("/") + "/"
GMAIL_USER   = os.environ.get("GMAIL_USER", "")
GMAIL_PASS   = os.environ.get("GMAIL_APP_PASSWORD", "")
SITE_NAME    = os.environ.get("SITE_NAME", "汪喵回家")
MOA_API_URL  = os.environ.get("MOA_API_URL") or \
    "https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=QcbUEzN6E6DL"
UA = "WangHome/1.0 (+lost-dog-matcher)"

if not SUPABASE_URL or not SERVICE_KEY:
    # 尚未設定 Secret 時安靜略過，避免排程每次失敗寄錯誤信
    print("尚未設定 SUPABASE_SERVICE_KEY，略過本次執行。請到 GitHub → Settings → Secrets → Actions 新增。"); sys.exit(0)

# ---------------------------------------------------------------- Supabase REST
def sb(method, path, body=None, params=None, prefer=None):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    if params: url += "?" + urllib.parse.urlencode(params, safe=",.*()")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("apikey", SERVICE_KEY)
    if SERVICE_KEY.startswith("eyJ"):  # 舊版 JWT service_role；新版 sb_secret_ 只需 apikey header
        req.add_header("Authorization", f"Bearer {SERVICE_KEY}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Prefer", prefer or "return=representation")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            t = r.read().decode()
            return json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        kind = "sb_secret" if SERVICE_KEY.startswith("sb_secret_") else "sb_publishable(錯誤：這是公開金鑰)" if SERVICE_KEY.startswith("sb_publishable_") else "JWT" if SERVICE_KEY.startswith("eyJ") else "未知格式"
        print(f"Supabase 回應 {e.code}：{body}")
        print(f"金鑰檢查：類型={kind}，長度={len(SERVICE_KEY)}，含遮罩符號={'•' in SERVICE_KEY or '*' in SERVICE_KEY}")
        raise

# ---------------------------------------------------------------- 農業部資料
def fetch_moa():
    req = urllib.request.Request(MOA_API_URL, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=25) as r:
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
        if not (ct & at): return -1  # 毛色明顯不同直接排除
        s += 25
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
    # 農業部開放資料擋台灣以外的 IP（GitHub Actions 連不上）。
    # 收容所比對已改在瀏覽器端進行；只有設定了 MOA_API_URL（例如台灣的代理）才在這裡跑。
    if not os.environ.get("MOA_API_URL"):
        print("收容所比對：由網站前端執行（未設定 MOA_API_URL，略過）"); return
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

# ---------------------------------------------------------------- 拾獲通報 ↔ 案件
import math
def _km(a_lat, a_lng, b_lat, b_lng):
    R = 6371; r = math.radians
    h = math.sin(r(b_lat - a_lat) / 2) ** 2 + math.cos(r(a_lat)) * math.cos(r(b_lat)) * math.sin(r(b_lng - a_lng) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))

def found_score(c, f):
    """與前端 matchScore() 同邏輯。"""
    if norm_city(c["lost_city"]) != norm_city(f["city"]): return -1
    if (c.get("species") or "dog") != (f.get("species") or "dog"): return -1
    try:
        lost = dt.datetime.fromisoformat(c["lost_at"].replace("Z", "+00:00"))
        seen = dt.datetime.fromisoformat(f["seen_at"].replace("Z", "+00:00"))
        if seen < lost - dt.timedelta(days=1) or seen > lost + dt.timedelta(days=60): return -1
    except Exception:
        pass
    s = 30
    a, b = colour_tokens(c.get("colour")), colour_tokens(f.get("colour"))
    if a and b:
        if not (a & b): return -1   # 毛色明顯不同直接排除
        s += 25
    if c.get("size") and f.get("size"): s += 15 if c["size"] == f["size"] else -10
    if c.get("sex") in ("male", "female") and f.get("sex") in ("male", "female"):
        s += 15 if c["sex"] == f["sex"] else -20
    if c.get("lost_district") and c.get("lost_district") == f.get("district"): s += 10
    if c.get("lost_lat") and f.get("lat"):
        d = _km(c["lost_lat"], c["lost_lng"], f["lat"], f["lng"])
        s += 15 if d < 2 else 8 if d < 5 else -10 if d > 20 else 0
    return max(0, min(100, s))

def run_found_matching():
    cases = sb("GET", "cases", params={"select": "id,species,lost_city,lost_district,lost_at,lost_lat,lost_lng,colour,size,sex", "status": "eq.searching"}) or []
    founds = sb("GET", "found_reports", params={"select": "id,species,city,district,seen_at,lat,lng,colour,size,sex", "status": "eq.open"}) or []
    if not cases or not founds: print("拾獲比對：無資料"); return
    existing = sb("GET", "found_matches", params={"select": "case_id,found_id"}) or []
    seen = {(m["case_id"], m["found_id"]) for m in existing}
    rows = []
    for c in cases:
        for f in founds:
            sc = found_score(c, f)
            if sc >= 45 and (c["id"], f["id"]) not in seen:
                rows.append({"case_id": c["id"], "found_id": f["id"], "score": sc})
    if rows: sb("POST", "found_matches", body=rows, prefer="return=minimal,resolution=ignore-duplicates")
    print(f"拾獲比對新增 {len(rows)} 筆")

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
    # 拾獲通報比對
    pend = sb("GET", "found_matches", params={"select": "id,case_id,found_id,score", "notified": "eq.false", "order": "score.desc"}) or []
    by_case = {}
    for m in pend: by_case.setdefault(m["case_id"], []).append(m)
    if by_case:
        fids = ",".join({m["found_id"] for m in pend})
        fr = {f["id"]: f for f in (sb("GET", "found_reports", params={"select": "id,kind,seen_at,city,district,place_text,colour,size,current_place", "id": f"in.({fids})"}) or [])}
    for cid, lst in by_case.items():
        c = cases.get(cid)
        if not c or not c.get("contact_email"): continue
        lines = [f"有網友登記了 {len(lst)} 筆可能是「{c['name']}」的拾獲／目擊通報：", ""]
        for m in lst[:10]:
            f = fr.get(m["found_id"], {})
            lines.append(f"・{'拾獲' if f.get('kind') == 'found' else '目擊'}  相似 {m['score']}  {fmt(f.get('seen_at', ''))}  {f.get('city', '')}{f.get('district') or ''} {f.get('place_text') or ''}")
            if f.get("current_place"): lines.append(f"  目前在：{f['current_place']}")
            lines.append(f"  {SITE_URL}#/found/{m['found_id']}")
            lines.append("")
        lines += ["請點連結看照片，並直接聯絡通報者。", "", f"— {SITE_NAME}"]
        try:
            send_mail(c["contact_email"], f"【{SITE_NAME}】有人可能撿到／看到 {c['name']}", "\n".join(lines))
            print(f"已通知拾獲比對：{c['name']} x{len(lst)}")
        except Exception as e:
            print("寄信失敗：", e); continue
        sb("PATCH", "found_matches", body={"notified": True}, params={"id": "in.(" + ",".join(m["id"] for m in lst) + ")"}, prefer="return=minimal")

# ---------------------------------------------------------------- 會員通知
SP_NAME = {"dog": "狗", "cat": "貓"}
def run_member_notifications():
    if not (GMAIL_USER and GMAIL_PASS):
        print("未設定 Gmail，略過會員通知"); return
    # 附近新案件
    rows = sb("POST", "rpc/nearby_targets", body={"p_hours": 26}) or []
    by_user = {}
    for r in rows: by_user.setdefault((r["user_id"], r["email"]), []).append(r)
    for (uid, email), lst in by_user.items():
        lines = [f"你家附近有 {len(lst)} 隻毛孩走失了，看到請拍照回報、不要追：", ""]
        for r in lst[:10]:
            lines.append(f"・{SP_NAME.get(r['species'], '')} {r['case_name']}（距離約 {r['distance_km']:.1f} 公里）{r['lost_city']}{r.get('lost_district') or ''} {r.get('lost_place') or ''}")
            lines.append(f"  {SITE_URL}#/case/{r['case_id']}")
        lines += ["", f"不想再收到？到「我的 → 通知設定」關閉：{SITE_URL}#/me", f"— {SITE_NAME}"]
        try:
            send_mail(email, f"【{SITE_NAME}】你家附近有毛孩走失", "\n".join(lines))
            sb("POST", "notify_log", body=[{"user_id": uid, "kind": "nearby", "ref_id": r["case_id"]} for r in lst],
               prefer="return=minimal,resolution=ignore-duplicates")
            print(f"附近通知：{len(lst)} 筆 → 1 位會員")
        except Exception as e:
            print("附近通知寄送失敗：", e)
    # 追蹤案件新目擊
    rows = sb("POST", "rpc/follow_targets", body={"p_hours": 26}) or []
    by_user = {}
    for r in rows: by_user.setdefault((r["user_id"], r["email"]), []).append(r)
    for (uid, email), lst in by_user.items():
        lines = ["你追蹤的案件有新的目擊：", ""]
        for r in lst[:15]:
            lines.append(f"・{r['case_name']}  {fmt(r['seen_at'])}  {r.get('place_text') or '（見地圖）'}")
            lines.append(f"  {SITE_URL}#/case/{r['case_id']}")
        lines += ["", f"管理追蹤與通知：{SITE_URL}#/me", f"— {SITE_NAME}"]
        try:
            send_mail(email, f"【{SITE_NAME}】追蹤的案件有新目擊", "\n".join(lines))
            sb("POST", "notify_log", body=[{"user_id": uid, "kind": "follow", "ref_id": r["sighting_id"]} for r in lst],
               prefer="return=minimal,resolution=ignore-duplicates")
            print(f"追蹤通知：{len(lst)} 筆 → 1 位會員")
        except Exception as e:
            print("追蹤通知寄送失敗：", e)

# ---------------------------------------------------------------- 檢舉通知站長
def run_report_alerts():
    admin = os.environ.get("ADMIN_EMAIL") or GMAIL_USER
    if not (GMAIL_USER and GMAIL_PASS and admin): return
    rows = sb("GET", "reports", params={"select": "id,target_type,target_id,reason,note,created_at", "notified": "eq.false", "order": "created_at.asc"}) or []
    if not rows: return
    names = {"case": "走失案件", "found": "拾獲通報", "sighting": "目擊"}
    lines = [f"有 {len(rows)} 則新檢舉待處理：", ""]
    for r in rows[:30]:
        lines.append(f"・{names.get(r['target_type'], r['target_type'])}  原因：{r['reason']}  {r.get('note') or ''}")
    lines += ["", f"管理後台：{SITE_URL}#/admin", f"— {SITE_NAME}"]
    try:
        send_mail(admin, f"【{SITE_NAME}】{len(rows)} 則新檢舉", "\n".join(lines))
        sb("PATCH", "reports", body={"notified": True}, params={"id": "in.(" + ",".join(r["id"] for r in rows) + ")"}, prefer="return=minimal")
        print(f"已通知站長 {len(rows)} 則檢舉")
    except Exception as e:
        print("檢舉通知失敗：", e)

# ---------------------------------------------------------------- main
if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    print("WangHome daily v1.5.0 mode =", mode, dt.datetime.now(dt.timezone.utc).isoformat())
    if mode == "probe":
        try:
            data = fetch_moa()
        except Exception as e:
            print("連不上農業部開放資料（多半是擋海外 IP）：", e); sys.exit(0)
        dogs = [x for x in data if (x.get("animal_kind") or "") == "狗"]
        print(f"其中狗：{len(dogs)} 筆")
        if data: print("欄位：", ", ".join(sorted(data[0].keys())))
        if dogs:
            d = dogs[0]
            print("範例：", {k: d.get(k) for k in ("shelter_name", "animal_colour", "animal_bodytype", "animal_sex", "animal_foundplace", "animal_createtime", "album_file")})
        sys.exit(0)
    if mode in ("all", "match"): run_matching()
    if mode in ("all", "match", "notify"): run_found_matching()
    if mode in ("all", "notify"): run_notifications()
    if mode in ("all", "notify"): run_member_notifications()
    if mode in ("all", "notify"): run_report_alerts()
    n = sb("GET", "cases", params={"select": "id", "limit": "1"})
    print("保活 OK", "有資料" if n else "空")

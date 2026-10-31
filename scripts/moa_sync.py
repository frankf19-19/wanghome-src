#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
汪喵回家 — 農業部「寵物遺失啟事」同步（GitHub Actions 每 6 小時）

把飼主在農業部寵物登記網申報的走失狗貓，匯入成本站的協尋案件（source='moa'），
讓它們也有協尋頁、海報、地圖、目擊回報。飼主撤銷申報後，這邊自動結案。

隱私：不存門牌地址、Email、飼主姓名；位置只到「縣市＋區」（地圖上標區的中心點）。
農業部只開放台灣網路，所以經由本站的轉接 https://wangmiaotw.com/api/moa/lost 讀取。

環境變數：SUPABASE_URL、SUPABASE_SERVICE_KEY
"""
import os, re, json, time, urllib.request, urllib.parse, datetime as dt
from concurrent.futures import ThreadPoolExecutor

SB = os.environ["SUPABASE_URL"].rstrip("/")
KEY = os.environ["SUPABASE_SERVICE_KEY"].strip()
SITE = "https://wangmiaotw.com/"
UA = "WangMiaoHome/1.0 (https://wangmiaotw.com; service@wangmiaotw.com)"
MAX_NEW = int(os.environ.get("MAX_NEW", "120"))      # 每次最多新增幾筆（照片檢查、地點查詢要時間）
MAX_GEO = int(os.environ.get("MAX_GEO", "50"))       # 每次最多查幾個新地區（Nominatim 每秒 1 次）
DAYS = 180

def http(url, method="GET", body=None, headers=None, timeout=40):
    h = {"User-Agent": UA}
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    if data is not None: h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read(), r.headers

def sb(method, path, body=None, prefer=None):
    h = {"apikey": KEY}
    if KEY.startswith("eyJ"): h["Authorization"] = "Bearer " + KEY
    if prefer: h["Prefer"] = prefer
    st, b, _ = http(f"{SB}/rest/v1/{path}", method, body, h, 60)
    return json.loads(b) if b else None

def norm_city(s):
    return s.replace("台", "臺", 1) if s.startswith("台") else s

ADDR = re.compile(r"^(..[市縣])(.{1,3}?[區鄉鎮市])?")
def parse_area(addr):
    a = re.sub(r"^\d{3,6}", "", str(addr or "")).strip()
    a = norm_city(a)
    m = ADDR.match(a)
    if not m: return "", ""
    return m.group(1), (m.group(2) or "")

def main():
    t0 = time.time()
    st, raw, _ = http(SITE + "api/moa/lost", timeout=60)
    print(f"::notice::讀到農業部資料 {len(raw)} bytes（{time.time()-t0:.1f} 秒）", flush=True)
    data = json.loads(raw)
    if not isinstance(data, list) or len(data) < 20:
        raise SystemExit(f"農業部資料不正常（{type(data).__name__} {len(data) if isinstance(data, list) else ''}），這次不同步")
    all_ids, rows = [], []
    cut = (dt.datetime.utcnow() + dt.timedelta(hours=8) - dt.timedelta(days=DAYS)).strftime("%Y/%m/%d")
    for a in data:
        pic = str(a.get("PICTURE") or "")
        m = re.search(r"File_No=([A-Za-z0-9]+)", pic)
        if not m: continue
        sid = "moa:" + m.group(1)
        all_ids.append(sid)
        d = str(a.get("遺失時間") or "")
        if not re.match(r"^\d{4}/\d{2}/\d{2}$", d) or d < cut: continue
        city, dist = parse_area(a.get("遺失地點"))
        if not city: continue                       # 沒寫縣市的無法放上地圖，略過
        sp = "cat" if a.get("寵物別") == "貓" else "dog"
        name = str(a.get("寵物名") or "").strip()[:20] or str(a.get("品種") or "").strip()[:20] or ("貓咪" if sp == "cat" else "狗狗")
        feat = "；".join(x for x in [str(a.get("特徵") or "").strip(), str(a.get("外觀") or "").strip()] if x)[:300]
        chip = re.sub(r"\D", "", str(a.get("晶片號碼") or ""))
        tel = re.sub(r"[^\d#+-]", "", str(a.get("連絡電話") or ""))[:20]
        rows.append({"source_id": sid, "file_no": m.group(1), "name": name, "species": sp,
            "breed": str(a.get("品種") or "").strip()[:40], "sex": {"公": "male", "母": "female"}.get(a.get("性別"), "unknown"),
            "colour": str(a.get("毛色") or "").strip()[:40], "features": feat, "chip_last4": chip[-4:] if len(chip) >= 10 else "",
            "lost_at": d.replace("/", "-") + "T12:00:00+08:00", "lost_city": city, "lost_district": dist, "contact_phone": tel})
    print(f"::notice::農業部申報 {len(data)} 筆，最近 {DAYS} 天有縣市的 {len(rows)} 筆", flush=True)

    have = {r["source_id"]: r for r in sb("GET", "cases?source=eq.moa&select=source_id,lost_lat,photos&limit=5000") or []}
    geo = {g["name"]: (g["lat"], g["lng"]) for g in sb("GET", "geo_cache?select=name,lat,lng&limit=5000") or []}
    out, n_new, n_geo = [], 0, 0
    for r in rows:
        fn = r.pop("file_no")
        if r["source_id"] in have:
            out.append(r); continue
        if n_new >= MAX_NEW: continue
        # 地點：區的中心點（查不到就用縣市）
        ll = None
        for key in ([r["lost_city"] + r["lost_district"]] if r["lost_district"] else []) + [r["lost_city"]]:
            if key in geo:
                if geo[key][0] is not None: ll = geo[key]; break
                continue
            if n_geo >= MAX_GEO: break
            n_geo += 1
            q = urllib.parse.urlencode({"q": key, "countrycodes": "tw", "format": "json", "limit": 1, "accept-language": "zh-TW"})
            try:
                _, b, _ = http("https://nominatim.openstreetmap.org/search?" + q, timeout=20)
                j = json.loads(b)
                v = (float(j[0]["lat"]), float(j[0]["lon"])) if j else (None, None)
            except Exception as e:
                print("查地點失敗", key, e, flush=True); v = None
            time.sleep(1.2)
            if v is None: break
            geo[key] = v
            sb("POST", "geo_cache", {"name": key, "lat": v[0], "lng": v[1]}, "resolution=merge-duplicates")
            if v[0] is not None: ll = v; break
        if not ll: continue                           # 下次再查
        r["lost_lat"], r["lost_lng"] = ll
        r["_pic"] = f"{SITE}api/petpic/{fn}.jpg"
        out.append(r); n_new += 1
    print(f"地點查好了（{time.time()-t0:.1f} 秒），檢查 {n_new} 張照片…", flush=True)
    # 照片：有照片才放（經由本站轉接，海報、分享圖卡才能用）
    def chk(r):
        u = r.pop("_pic", None)
        if not u: return
        try:
            st, b, h = http(u, timeout=15)
            r["photos"] = [u] if st == 200 and len(b) > 500 else []
        except Exception:
            r["photos"] = []
    with ThreadPoolExecutor(8) as ex: list(ex.map(chk, out))
    print(f"::notice::新增 {n_new} 筆，更新 {len(out) - n_new} 筆，新查地點 {n_geo} 個（{time.time()-t0:.1f} 秒）", flush=True)
    res = []
    for i in range(0, len(out), 100):
        last = i + 100 >= len(out)
        res.append(sb("POST", "rpc/moa_upsert", {"p_rows": out[i:i + 100], "p_all_ids": all_ids if last else None}))
    if not out:
        res.append(sb("POST", "rpc/moa_upsert", {"p_rows": [], "p_all_ids": all_ids}))
    print("::notice::結果", json.dumps(res, ensure_ascii=False), flush=True)

if __name__ == "__main__":
    import traceback, urllib.error
    try:
        main()
    except urllib.error.HTTPError as e:
        body = e.read()[:400].decode("utf-8", "replace").replace("\n", " ")
        print(f"::error::HTTP {e.code} {e.url[:120]} {body}", flush=True); raise SystemExit(1)
    except Exception as e:
        tb = traceback.format_exc().replace("\n", " | ")[-900:]
        print(f"::error::{tb}", flush=True); raise SystemExit(1)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
汪喵回家 — 收容所比對＋照片相似度（GitHub Actions 每 6 小時）

1. 對所有協尋中的案件（本站登記＋農業部申報），用農業部收容所資料做條件比對
   （走失後才收容、同縣市、毛色、體型、性別），寫入 shelter_matches（和網站前端同一套規則）。
2. 有照片的比對結果，用 AI 影像模型（DINOv2，免費、在 GitHub 主機上跑）算出照片相似度 0～100，
   寫回 shelter_matches.photo_sim。網站只把「照片也像」的排在前面。

環境變數：SUPABASE_URL、SUPABASE_SERVICE_KEY
"""
import os, re, io, json, time, datetime as dt, urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor

SB = os.environ["SUPABASE_URL"].rstrip("/")
KEY = os.environ["SUPABASE_SERVICE_KEY"].strip()
SITE = "https://wangmiaotw.com/"
UA = "WangMiaoHome/1.0 (https://wangmiaotw.com; service@wangmiaotw.com)"
MAX_CMP = int(os.environ.get("MAX_CMP", "600"))
AREA = {"臺北市":2,"新北市":3,"基隆市":4,"宜蘭縣":5,"桃園市":6,"新竹縣":7,"新竹市":8,"苗栗縣":9,"臺中市":10,"彰化縣":11,"南投縣":12,"雲林縣":13,"嘉義縣":14,"嘉義市":15,"臺南市":16,"高雄市":17,"屏東縣":18,"花蓮縣":19,"臺東縣":20,"澎湖縣":21,"金門縣":22,"連江縣":23}
GROUPS = {'黑':['黑'],'白':['白'],'黃':['黃','米','淺棕','卡其','金'],'棕':['棕','咖啡','褐','茶'],'虎斑':['虎斑','斑'],'灰':['灰','銀'],'花':['花','三色','黑白','黃白','雙色'],'紅':['紅','橘']}
SIZE = {"small": "SMALL", "medium": "MEDIUM", "large": "BIG"}
BODY = {"SMALL": "小型", "MEDIUM": "中型", "BIG": "大型"}

def note(msg): print("::notice::" + msg, flush=True)

def http(url, method="GET", body=None, headers=None, timeout=40):
    h = {"User-Agent": UA}; h.update(headers or {})
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

def sb_all(path):
    out = []
    for off in range(0, 50000, 1000):
        part = sb("GET", f"{path}&limit=1000&offset={off}") or []
        out += part
        if len(part) < 1000: break
    return out

def colour_set(s):
    s = s or ""
    return {g for g, ks in GROUPS.items() if any(k in s for k in ks)}

def moa_pic(u):
    u = str(u or "").strip()
    if u.lower().startswith("http://"): u = "https://" + u[7:]
    return u if re.match(r"^https://[^\s'\"()<>\\]+$", u) else ""

def tw_day(ts):
    t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00")) + dt.timedelta(hours=8)
    return t.date()

def score(c, a):
    """和網站 shelterScore() 相同的規則"""
    if a.get("animal_status") and a["animal_status"] != "OPEN": return -1
    created = (a.get("animal_createtime") or "").replace("/", "-")[:10]
    min_day = (tw_day(c["lost_at"]) - dt.timedelta(days=1)).isoformat()
    if not created or created < min_day: return -1
    s = 40
    cs, as_ = colour_set(c.get("colour")), colour_set(a.get("animal_colour"))
    if cs and as_:
        if not (cs & as_): return -1
        s += 25
    if c.get("size") and a.get("animal_bodytype"): s += 15 if SIZE.get(c["size"]) == a["animal_bodytype"] else -10
    if c.get("sex") in ("male", "female") and a.get("animal_sex") in ("M", "F"):
        s += 15 if (c["sex"] == "male") == (a["animal_sex"] == "M") else -25
    d = re.sub(r"[區鄉鎮市]$", "", c.get("lost_district") or "")
    if d and d in (a.get("animal_foundplace") or ""): s += 10
    return max(0, min(100, s))

def matching(cases):
    by = {}
    for c in cases: by.setdefault((c["lost_city"], c["species"]), []).append(c)
    rows = []
    for (city, sp), lst in by.items():
        area = AREA.get(city)
        if not area: continue
        kind = "貓" if sp == "cat" else "狗"
        try:
            _, b, _ = http(f"{SITE}api/moa/shelter?area={area}&kind={urllib.parse.quote(kind)}", timeout=60)
            animals = json.loads(b)
        except Exception as e:
            note(f"讀收容所資料失敗 {city}{kind}：{e}"); continue
        for c in lst:
            hits = sorted(((score(c, a), a) for a in animals), key=lambda x: (-x[0], x[1].get("animal_createtime") or ""))
            for s, a in [h for h in hits if h[0] >= 55][:20]:
                age = a.get("animal_age")
                rows.append({"case_id": c["id"], "animal_id": str(a.get("animal_id")), "animal_subid": a.get("animal_subid"),
                    "shelter_name": a.get("shelter_name"), "shelter_tel": a.get("shelter_tel"), "shelter_address": a.get("shelter_address"),
                    "found_place": a.get("animal_foundplace"), "colour": a.get("animal_colour"), "bodytype": BODY.get(a.get("animal_bodytype"), a.get("animal_bodytype")),
                    "sex": {"M": "公", "F": "母"}.get(a.get("animal_sex"), "不明"),
                    "age": {"CHILD": "幼貓" if sp == "cat" else "幼犬", "ADULT": "成貓" if sp == "cat" else "成犬"}.get(age, age),
                    "variety": (a.get("animal_Variety") or "").strip(), "photo_url": moa_pic(a.get("album_file")) or None,
                    "open_date": a.get("animal_opendate") or None, "score": s})
    for i in range(0, len(rows), 200):
        sb("POST", "shelter_matches?on_conflict=case_id,animal_id", rows[i:i + 200], "return=minimal,resolution=ignore-duplicates")
    note(f"收容所條件比對：{len(cases)} 個案件，符合條件 {len(rows)} 筆（已存在的略過）")

# ---------------------------------------------------------------- 照片相似度
_model = None
def model():
    global _model
    if _model is None:
        import torch
        from transformers import AutoImageProcessor, AutoModel
        proc = AutoImageProcessor.from_pretrained("facebook/dinov2-small")
        m = AutoModel.from_pretrained("facebook/dinov2-small").eval()
        _model = (torch, proc, m)
    return _model

ERR = {}
def fetch_img(url):
    from PIL import Image, ImageOps
    try:
        st, b, h = http(url, timeout=30)
        if st != 200 or len(b) < 800: ERR.setdefault("small", url); return None
        im = ImageOps.exif_transpose(Image.open(io.BytesIO(b))).convert("RGB")
        im.thumbnail((640, 640))
        return im
    except Exception as e:
        ERR.setdefault(type(e).__name__, f"{url[:90]} {str(e)[:120]}")
        return None

_emb = {}
def embed(url, im):
    if url in _emb: return _emb[url]
    torch, proc, m = model()
    with torch.no_grad():
        x = proc(images=im, return_tensors="pt")
        o = m(**x)
        cls = o.last_hidden_state[:, 0]
        patch = o.last_hidden_state[:, 1:].mean(1)
        v = torch.cat([cls, patch], dim=1)[0]
        v = v / v.norm()
    _emb[url] = v
    return v

def photo_sim():
    cases = {c["id"]: c for c in sb_all("cases?status=eq.searching&hidden=eq.false&select=id,photos")}
    ms = sb_all("shelter_matches?dismissed=eq.false&select=id,case_id,animal_subid,photo_url,photo_sim,photo_checked_at")
    now = dt.datetime.now(dt.timezone.utc)
    todo = []
    for m in ms:
        if m["case_id"] not in cases: continue
        if m["photo_sim"] is None: todo.append(m); continue
        if m["photo_sim"] == -1:   # 沒照片：每 12 小時再試（收容所可能補照片）
            t = m.get("photo_checked_at")
            if not t or now - dt.datetime.fromisoformat(t.replace("Z", "+00:00")) > dt.timedelta(hours=12): todo.append(m)
    hasph = lambda m: bool((cases[m["case_id"]].get("photos") or [None])[0])
    todo.sort(key=lambda m: (not hasph(m), m["photo_sim"] is not None))
    todo = todo[:MAX_CMP]
    note(f"照片比對：待比對 {len(todo)} 筆")
    if not todo: return
    urls = set()
    for m in todo:
        ph = (cases[m["case_id"]].get("photos") or [None])[0]
        m["_cu"] = ph
        sub = (m.get("animal_subid") or "").strip()
        m["_su"] = moa_pic(m.get("photo_url")) or (f"{SITE}api/shelterpic/{sub}.jpg?v=3" if re.match(r"^[A-Z]{5}[0-9]{6,}$", sub) else None)
        if m["_cu"] and m["_su"]:
            urls.add(m["_cu"]); urls.add(m["_su"])
    with ThreadPoolExecutor(12) as ex:
        imgs = dict(zip(urls, ex.map(fetch_img, urls)))
    ok_c = sum(1 for u, v in imgs.items() if v is not None and "supabase.co" in u)
    ok_s = sum(1 for u, v in imgs.items() if v is not None and "supabase.co" not in u)
    note(f"下載照片：{len(urls)} 張，走失毛孩照片成功 {ok_c}，收容所照片成功 {ok_s}；錯誤範例 {json.dumps(ERR, ensure_ascii=False)[:400]}")
    sims, done = [], 0
    for m in todo:
        ci, si = imgs.get(m["_cu"]) if m["_cu"] else None, imgs.get(m["_su"]) if m["_su"] else None
        patch = {"photo_checked_at": now.isoformat()}
        if ci is None or si is None:
            patch["photo_sim"] = -1
        else:
            cos = float((embed(m["_cu"], ci) * embed(m["_su"], si)).sum())
            sims.append(cos)
            # 換算成 0～100（0.30 以下＝不像，0.80 以上＝非常像；之後依實際分布再調）
            patch["photo_sim"] = int(round(max(0, min(1, (cos - 0.30) / 0.50)) * 100))
            if not moa_pic(m.get("photo_url")) and m["_su"]: patch["photo_url"] = m["_su"]
        sb("PATCH", f"shelter_matches?id=eq.{m['id']}", patch, "return=minimal")
        done += 1
    if sims:
        s = sorted(sims)
        q = lambda p: s[min(len(s) - 1, int(p * len(s)))]
        note(f"照片比對完成 {done} 筆，有照片 {len(sims)} 筆；相似度分布 min {s[0]:.2f} p25 {q(.25):.2f} p50 {q(.5):.2f} p75 {q(.75):.2f} p90 {q(.9):.2f} max {s[-1]:.2f}")
    else:
        note(f"照片比對完成 {done} 筆（都沒有照片）")

def main():
    cases = sb_all("cases?status=eq.searching&hidden=eq.false&select=id,species,lost_city,lost_district,lost_at,colour,size,sex")
    matching(cases)
    photo_sim()

if __name__ == "__main__":
    import traceback, urllib.error
    try:
        main()
    except urllib.error.HTTPError as e:
        body = e.read()[:400].decode("utf-8", "replace").replace("\n", " ")
        print(f"::error::HTTP {e.code} {e.url[:120]} {body}", flush=True); raise SystemExit(1)
    except Exception:
        print("::error::" + traceback.format_exc().replace("\n", " | ")[-900:], flush=True); raise SystemExit(1)

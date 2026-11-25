# 汪喵回家 — 找出要自動發文、還沒有 Reel 的網友協尋案件，做 Reel＋海報，上傳到 Supabase Storage
# 由 .github/workflows/auto-reel.yml 執行。之後 Edge Function social-post 會拿這兩個檔案發 FB／IG／Threads。
# 篩選條件和 social-post 一樣：協尋中、飼主同意分享、還沒發、沒隱藏、網站登記、72 小時內、不是站長自己登記、有照片
import json, os, subprocess, sys, tempfile, urllib.error, urllib.request, urllib.parse
from datetime import datetime, timedelta, timezone

SB = "https://nopyhfpaykkiieudvoko.supabase.co"
KEY = os.environ.get("SUPABASE_SERVICE_KEY", "").strip().strip('"').strip("'")
HERE = os.path.dirname(os.path.abspath(__file__))
PHOTO_RE = SB + "/storage/v1/object/public/photos/"
MAX_PER_RUN = 3

def req(method, path, body=None, ctype="application/json", extra=None):
    data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
    r = urllib.request.Request(SB + path, data=data, method=method)
    r.add_header("apikey", KEY)
    if KEY.startswith("eyJ"): r.add_header("Authorization", "Bearer " + KEY)
    if data is not None: r.add_header("Content-Type", ctype)
    for k, v in (extra or {}).items(): r.add_header(k, v)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp:
            t = resp.read()
            return json.loads(t) if t and resp.headers.get("content-type", "").startswith("application/json") else None
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path.split('?')[0]} HTTP {e.code} {e.read()[:200].decode('utf-8', 'replace')}")

def todo():
    now = datetime.now(timezone.utc)
    q = urllib.parse.urlencode([
        ("select", "id,name,species,sex,age_text,breed,colour,features,collar_desc,has_chip,lost_at,lost_city,lost_district,lost_place,photos,owner_id,contact_name,contact_phone,phone_public,created_at"),
        ("status", "eq.searching"), ("social_ok", "is.true"), ("social_posted_at", "is.null"), ("social_reel_url", "is.null"),
        ("hidden", "not.is.true"), ("or", "(source.is.null,source.eq.site)"),
        ("created_at", "lt." + (now - timedelta(minutes=10)).isoformat()), ("created_at", "gt." + (now - timedelta(hours=72)).isoformat()),
        ("order", "created_at.asc"), ("limit", "20")])
    rows = req("GET", "/rest/v1/cases?" + q) or []
    admins = {x["id"] for x in (req("GET", "/rest/v1/profiles?select=id&is_admin=is.true") or [])}
    out = []
    for c in rows:
        ph = [p for p in (c.get("photos") or []) if isinstance(p, str) and p.startswith(PHOTO_RE) and p.lower().split("?")[0].endswith((".jpg", ".jpeg"))]
        if not ph or not (c.get("name") or "").strip() or not c.get("lost_city"): continue
        if c.get("owner_id") in admins: continue
        lost = datetime.fromisoformat(c["lost_at"].replace("Z", "+00:00"))
        if now - lost > timedelta(days=30): continue
        c["_photos"] = ph[:3]; out.append(c)
    return out[:MAX_PER_RUN]

def main():
    if not KEY: print("沒有 SUPABASE_SERVICE_KEY"); return
    try: cs = todo()
    except Exception as e:
        # 資料庫還沒加欄位、金鑰失效…：記下來，不讓排程一直失敗寄信
        print("查詢失敗", str(e)[:300]); cs = []
    print("要做 Reel 的案件", len(cs))
    if "--check" in sys.argv:
        with open(os.environ.get("GITHUB_OUTPUT", "/dev/null"), "a") as f: f.write(f"n={len(cs)}\n")
        return
    for c in cs:
        try:
            with tempfile.TemporaryDirectory() as d:
                loc = []
                for i, u in enumerate(c["_photos"]):
                    p = os.path.join(d, f"p{i}.jpg"); urllib.request.urlretrieve(u, p); loc.append(p)
                cj = {k: v for k, v in c.items() if not k.startswith("_")}
                if not c.get("phone_public"): cj["contact_phone"] = ""
                cj["photos_local"] = loc
                json.dump(cj, open(os.path.join(d, "c.json"), "w"), ensure_ascii=False)
                r = subprocess.run([sys.executable, os.path.join(HERE, "auto_reel.py"), os.path.join(d, "c.json"), os.path.join(d, "out")], capture_output=True, text=True, timeout=600)
                if r.returncode: raise RuntimeError(r.stderr[-400:])
                urls = {}
                for name, ct in (("reel.mp4", "video/mp4"), ("poster.jpg", "image/jpeg")):
                    path = f"social/{c['id']}_{name}"
                    req("POST", f"/storage/v1/object/photos/{path}", open(os.path.join(d, "out", name), "rb").read(), ct, {"x-upsert": "true"})
                    urls[name] = f"{SB}/storage/v1/object/public/photos/{path}"
                req("PATCH", f"/rest/v1/cases?id=eq.{c['id']}", {"social_reel_url": urls["reel.mp4"], "social_poster_url": urls["poster.jpg"]}, extra={"Prefer": "return=minimal"})
                print("完成", c["id"], r.stdout.strip())
        except Exception as e:
            print("失敗", c["id"], str(e)[:400])

if __name__ == "__main__":
    main()

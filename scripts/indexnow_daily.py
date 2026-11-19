#!/usr/bin/env python3
"""每天把最近有變動的協尋案件頁送給 IndexNow（Bing、Yandex 等；ChatGPT 搜尋主要用 Bing）。
Cloudflare 機房送出時常被 Bing 擋（共用 IP 太多），所以改由 GitHub Actions 送。
週日另外把整份 sitemap 裡的非領養頁（首頁、指南、各縣市、鄉鎮、案件）全部送一次。"""
import json, re, sys, urllib.request, datetime, urllib.parse
SITE = "https://wangmiaotw.com/"
KEY = "73080c78bdeeab41a5d6fcb7fa0d1bc7"
SB = "https://nopyhfpaykkiieudvoko.supabase.co/rest/v1/"
ANON = "sb_publishable_WCeVQIAPH0UEEzhTwovqkg_lJ8Qjydb"
EPS = ["https://www.bing.com/indexnow", "https://api.indexnow.org/indexnow", "https://yandex.com/indexnow"]

def get(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": "wangmiaotw-indexnow/1.0", **(headers or {})})
    with urllib.request.urlopen(req, timeout=60) as r: return r.read()

def recent_cases(hours=30):
    since = (datetime.datetime.utcnow() - datetime.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    q = f"cases_public?last_activity=gte.{since}&select=id&limit=2000"
    rows = json.loads(get(SB + q, {"apikey": ANON, "Authorization": "Bearer " + ANON}))
    return [f"{SITE}p/{r['id']}" for r in rows]

def sitemap_core():
    xml = get(SITE + "sitemap.xml").decode("utf-8")
    locs = re.findall(r"<loc>([^<]+)</loc>", xml)
    return [u for u in locs if "/adopt/" not in u]

def send(urls):
    ok = False
    for i in range(0, len(urls), 9000):
        body = json.dumps({"host": "wangmiaotw.com", "key": KEY, "keyLocation": f"{SITE}{KEY}.txt", "urlList": urls[i:i + 9000]}).encode()
        for ep in EPS:
            try:
                req = urllib.request.Request(ep, data=body, method="POST", headers={"Content-Type": "application/json; charset=utf-8"})
                with urllib.request.urlopen(req, timeout=60) as r: st = r.status
            except urllib.error.HTTPError as e: st = e.code
            except Exception as e: st = str(e)[:60]
            print(ep, len(urls[i:i + 9000]), st); ok = ok or st in (200, 202)
    return ok

if __name__ == "__main__":
    full = "--full" in sys.argv or datetime.datetime.utcnow().weekday() == 6
    urls = sitemap_core() if full else recent_cases()
    urls = list(dict.fromkeys(urls + [SITE, f"{SITE}l/", f"{SITE}g/", f"{SITE}llms.txt", f"{SITE}llms-full.txt"]))
    print("full" if full else "recent", len(urls))
    sys.exit(0 if send(urls) else 1)

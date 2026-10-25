#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
汪喵回家 — 產生分享預覽頁  v1.5.0

網站是單頁 App（#/case/xxx），LINE / Facebook 抓不到每個案件的照片與標題。
這支腳本替每個公開案件、拾獲通報產生一個靜態頁：
  s/<case_id>.html   f/<found_id>.html
裡面有 og:title / og:description / og:image，訪客打開會立刻轉到真正的案件頁。
只讀公開資料（publishable key），不需要任何秘密金鑰。
"""
import os, sys, json, html, urllib.request, urllib.parse, datetime as dt, pathlib

SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://nopyhfpaykkiieudvoko.supabase.co").rstrip("/")
ANON_KEY     = os.environ.get("SUPABASE_ANON_KEY", "sb_publishable_WCeVQIAPH0UEEzhTwovqkg_lJ8Qjydb")
SITE_URL     = os.environ.get("SITE_URL", "https://wangmiaotw.com/").rstrip("/") + "/"
SITE_NAME    = os.environ.get("SITE_NAME", "汪喵回家")
ROOT         = pathlib.Path(__file__).resolve().parent.parent

SP = {"dog": ("狗", "尋狗啟事", "犬"), "cat": ("貓", "尋貓啟事", "貓")}
SEX = {"male": "公", "female": "母"}
SIZE = {"small": "小型", "medium": "中型", "large": "大型"}

def get(path, params):
    url = f"{SUPABASE_URL}/rest/v1/{path}?" + urllib.parse.urlencode(params, safe=",.*()")
    req = urllib.request.Request(url, headers={"apikey": ANON_KEY, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())

def get_all(path, params, page=1000, cap=20000):
    """PostgREST 單次最多回 1000 筆；分頁抓完，避免分享頁被誤刪。"""
    out, off = [], 0
    while off < cap:
        p = dict(params); p["limit"] = str(page); p["offset"] = str(off); p.setdefault("order", "id")
        rows = get(path, p)
        out += rows
        if len(rows) < page: break
        off += page
    return out

def days_since(ts):
    try:
        d = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return max(1, (dt.datetime.now(dt.timezone.utc) - d).days + 1)
    except Exception:
        return None

def page(title, desc, image, target, canonical):
    t, d = html.escape(title), html.escape(desc)
    img = html.escape(image or SITE_URL + "og.png")
    tgt = html.escape(target)
    return f"""<!DOCTYPE html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{t}</title>
<meta name="description" content="{d}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="{html.escape(SITE_NAME)}">
<meta property="og:title" content="{t}">
<meta property="og:description" content="{d}">
<meta property="og:image" content="{img}">
<meta property="og:url" content="{html.escape(canonical)}">
<meta property="og:locale" content="zh_TW">
<meta property="og:image:alt" content="{t}">
<meta name="twitter:card" content="summary_large_image">
<link rel="canonical" href="{html.escape(canonical)}">
<link rel="icon" href="{SITE_URL}icon.svg" type="image/svg+xml">
<style>body{{font-family:system-ui,"PingFang TC","Microsoft JhengHei",sans-serif;text-align:center;padding:40px 16px;color:#333}}img{{max-width:280px;border-radius:12px}}a{{color:#c8201f}}</style>
</head><body>
<img src="{img}" alt=""><h1>{t}</h1><p>{d}</p><p><a href="{tgt}">前往{html.escape(SITE_NAME)}查看 →</a></p>
<script>location.replace({json.dumps(target)});</script>
</body></html>
"""

def main():
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=60)).isoformat()
    cases = get_all("cases_public", {"select": "id,species,name,status,breed,sex,size,colour,features,lost_city,lost_district,lost_place,lost_at,photos,reward,last_seen_at,updated_at",
                                 "or": f"(status.eq.searching,updated_at.gte.{since})"})
    founds = get_all("found_public", {"select": "id,species,kind,status,colour,size,sex,city,district,place_text,seen_at,photos,current_place,updated_at,injury",
                                  "or": f"(status.eq.open,updated_at.gte.{since})"})
    sdir, fdir = ROOT / "s", ROOT / "f"
    sdir.mkdir(exist_ok=True); fdir.mkdir(exist_ok=True)
    want_s, want_f, changed = set(), set(), 0

    for c in cases:
        name, poster, unit = SP.get(c.get("species") or "dog", SP["dog"])
        if c["status"] == "found":
            title = f"🎉 {c['name']} 已經找到了！｜{SITE_NAME}"
        elif c["status"] != "searching":
            title = f"{c['name']}（協尋已結束）｜{SITE_NAME}"
        else:
            # 用「走失日期」而不是「第幾天」：分享預覽頁不常重新產生，天數會過期
            try:
                ld = dt.datetime.fromisoformat(c["lost_at"].replace("Z", "+00:00")).astimezone(dt.timezone(dt.timedelta(hours=8)))
                when = f"・{ld.month}/{ld.day} 走失"
            except Exception:
                when = ""
            title = f"【{poster}】{c['name']}｜{c['lost_city']}{c.get('lost_district') or ''}{when}"
        look = "・".join(x for x in [c.get("breed"), SEX.get(c.get("sex")), (SIZE.get(c.get("size")) or "") + unit if c.get("size") else None, c.get("colour")] if x)
        bits = [look, c.get("features") or ""]
        if c.get("reward"): bits.append(f"尋獲獎金 NT${c['reward']:,}")
        if c.get("lost_place"): bits.append("走失地點：" + c["lost_place"])
        if c["status"] == "searching": bits.append("看到請勿呼喊追趕，拍照記下時間地點，點連結回報目擊。")
        desc = "　".join(b for b in bits if b)[:190]
        img = (c.get("photos") or [None])[0]
        target = f"{SITE_URL}#/case/{c['id']}"
        fn = sdir / f"{c['id']}.html"
        content = page(title, desc, img, target, f"{SITE_URL}s/{c['id']}")
        want_s.add(fn.name)
        if not fn.exists() or fn.read_text(encoding="utf-8") != content:
            fn.write_text(content, encoding="utf-8"); changed += 1

    for f in founds:
        name, _, _ = SP.get(f.get("species") or "dog", SP["dog"])
        kind = "受傷" if f["kind"] == "injured" else "拾獲" if f["kind"] == "found" else "目擊"
        tail = "這是你的毛孩嗎？" if f.get("status") == "open" else ("已經回到主人身邊" if f.get("status") == "reunited" else "通報已結束")
        title = f"【{kind}{name}】{(SIZE.get(f.get('size')) or '')}{f.get('colour') or ''}{name}｜{f['city']}{f.get('district') or ''}｜{tail}"
        bits = [("傷勢：" + f["injury"]) if f.get("injury") else "", f.get("place_text") or "", ("目前在：" + f["current_place"]) if f.get("current_place") else "", "點連結看照片並聯絡通報者。"]
        desc = "　".join(b for b in bits if b)[:190]
        img = (f.get("photos") or [None])[0]
        target = f"{SITE_URL}#/found/{f['id']}"
        fn = fdir / f"{f['id']}.html"
        content = page(title, desc, img, target, f"{SITE_URL}f/{f['id']}")
        want_f.add(fn.name)
        if not fn.exists() or fn.read_text(encoding="utf-8") != content:
            fn.write_text(content, encoding="utf-8"); changed += 1

    # 刪除已隱藏／過期的分享頁
    removed = 0
    for d, want in ((sdir, want_s), (fdir, want_f)):
        for p in d.glob("*.html"):
            if p.name not in want:
                p.unlink(); removed += 1
    for d in (sdir, fdir):
        keep = d / ".keep"
        if not keep.exists(): keep.write_text("")
    print(f"案件 {len(cases)}、拾獲 {len(founds)}；更新 {changed} 頁、移除 {removed} 頁")

if __name__ == "__main__":
    main()

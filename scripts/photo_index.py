#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
汪喵回家 — 照片找毛孩：建立照片特徵索引（GitHub Actions 每 6 小時）

1. 協尋中的案件、開放中的拾獲通報、全台收容所開放領養的毛孩：每張照片用 DINOv2 算出特徵，存進 photo_vecs。
   已經算過的不重算；下架的（找到了、被領養了）會刪掉。
2. 目擊回報有附照片的：和走失毛孩的照片比對，把相似度（0～100）寫回 sightings.photo_sim。

環境變數：SUPABASE_URL、SUPABASE_SERVICE_KEY；MAX_NEW＝這次最多新算幾張（預設 2500）
"""
import os, json, time, urllib.parse
from concurrent.futures import ThreadPoolExecutor
from photo_match import SB, sb, sb_all, http, note, moa_pic, fetch_img, embed, AREA, BODY, UA

MAX_NEW = int(os.environ.get("MAX_NEW", "2500"))
CITY = {v: k for k, v in AREA.items()}
T0 = time.time(); BUDGET = int(os.environ.get("BUDGET_SEC", "1200"))

def wanted():
    """現在應該在索引裡的照片：{(kind, ref, url): info}"""
    w = {}
    for c in sb_all("cases?status=eq.searching&hidden=eq.false&select=id,name,species,photos,lost_city,lost_district,lost_at&order=lost_at.desc"):
        for u in (c.get("photos") or [])[:2]:
            if u: w[("case", c["id"], u)] = {"name": c.get("name"), "sp": c.get("species"), "city": c.get("lost_city"), "district": c.get("lost_district"), "at": c.get("lost_at")}
    for f in sb_all("found_reports?status=eq.open&select=id,kind,photos,city,district,seen_at,colour,hidden&order=seen_at.desc"):
        if f.get("hidden"): continue
        for u in (f.get("photos") or [])[:2]:
            if u: w[("found", f["id"], u)] = {"k": f.get("kind"), "city": f.get("city"), "district": f.get("district"), "at": f.get("seen_at"), "colour": f.get("colour")}
    for kind in ("狗", "貓"):
        try:
            st, b, _ = http("https://data.moa.gov.tw/Service/OpenData/TransService.aspx?UnitId=QcbUEzN6E6DL&animal_kind=" + urllib.parse.quote(kind), timeout=120)
            rows = json.loads(b)
        except Exception as e:
            note(f"農業部收容所資料讀不到（{kind}）：{str(e)[:120]}；這次保留原本的收容所索引"); return w, False
        for a in rows:
            if a.get("animal_status") != "OPEN": continue
            u = moa_pic(a.get("album_file"))
            if not u: continue
            w[("shelter", str(a.get("animal_id")), u)] = {"sp": "cat" if kind == "貓" else "dog", "city": CITY.get(a.get("animal_area_pkid")), "shelter": a.get("shelter_name"),
                "variety": (a.get("animal_Variety") or "").strip(), "colour": a.get("animal_colour"), "sex": {"M": "公", "F": "母"}.get(a.get("animal_sex"), ""),
                "body": BODY.get(a.get("animal_bodytype"), ""), "sub": a.get("animal_subid"), "at": (a.get("animal_createtime") or "").replace("/", "-")[:10]}
    return w, True

def vec_str(v): return "[" + ",".join(f"{x:.5f}" for x in v.tolist()) + "]"

def index():
    w, shelter_ok = wanted()
    have = {(r["kind"], r["ref"], r["url"]): r["id"] for r in sb_all("photo_vecs?select=id,kind,ref,url")}
    # 下架的刪掉（收容所資料讀不到時，不動收容所那部分）
    gone = [i for k, i in have.items() if k not in w and (shelter_ok or k[0] != "shelter")]
    for i in range(0, len(gone), 150):
        sb("DELETE", "photo_vecs?id=in.(" + ",".join(map(str, gone[i:i + 150])) + ")", prefer="return=minimal")
    todo = [k for k in w if k not in have]
    # 先算案件和拾獲（數量少、最重要），再算收容所
    todo.sort(key=lambda k: {"case": 0, "found": 1, "shelter": 2}[k[0]])
    todo = todo[:MAX_NEW]
    done = fail = 0
    for i in range(0, len(todo), 24):
        if time.time() - T0 > BUDGET: break
        part = todo[i:i + 24]
        with ThreadPoolExecutor(8) as ex: ims = list(ex.map(lambda k: fetch_img(k[2]), part))
        rows = []
        for k, im in zip(part, ims):
            if im is None: fail += 1; continue
            try: v = embed(k[2], im)
            except Exception: fail += 1; continue
            rows.append({"kind": k[0], "ref": k[1], "url": k[2], "vec": vec_str(v), "info": w[k]})
        if rows:
            sb("POST", "photo_vecs?on_conflict=kind,ref,url", rows, "return=minimal,resolution=merge-duplicates"); done += len(rows)
    left = len([k for k in w if k not in have]) - done - fail
    note(f"照片索引：應有 {len(w)} 張，原有 {len(have)}，刪除 {len(gone)}，新增 {done}，讀不到 {fail}，還沒算 {max(0, left)}")

def sightings():
    """目擊回報的照片 vs 走失毛孩的照片"""
    ss = sb_all("sightings?photo_url=not.is.null&photo_sim=is.null&status=neq.rejected&select=id,case_id,photo_url&order=created_at.desc")
    if not ss: note("目擊照片比對：沒有新的"); return
    ids = sorted({s["case_id"] for s in ss})
    cases = {}
    for i in range(0, len(ids), 80):
        for c in sb_all("cases?id=in.(" + ",".join(ids[i:i + 80]) + ")&select=id,photos"): cases[c["id"]] = [u for u in (c.get("photos") or [])[:3] if u]
    n = 0
    for s in ss[:300]:
        if time.time() - T0 > BUDGET + 240: break
        ph = cases.get(s["case_id"]) or []
        im = fetch_img(s["photo_url"]) if ph else None
        best = None
        if im is not None:
            a = embed(s["photo_url"], im)
            for u in ph:
                cim = fetch_img(u)
                if cim is None: continue
                cos = float((a * embed(u, cim)).sum())
                best = cos if best is None else max(best, cos)
        sim = -1 if best is None else int(round(max(0, min(1, (best - 0.30) / 0.50)) * 100))
        sb("PATCH", f"sightings?id=eq.{s['id']}", {"photo_sim": sim}, "return=minimal"); n += 1
    note(f"目擊照片比對：{n} 則")

if __name__ == "__main__":
    import traceback, urllib.error
    try:
        index(); sightings()
    except urllib.error.HTTPError as e:
        body = e.read()[:400].decode("utf-8", "replace").replace("\n", " ")
        print(f"::error::HTTP {e.code} {e.url[:120]} {body}", flush=True); raise SystemExit(1)
    except Exception:
        print("::error::" + traceback.format_exc().replace("\n", " | ")[-900:], flush=True); raise SystemExit(1)

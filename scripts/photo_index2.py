#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
汪喵回家 — 照片比對的第二個模型（只在主機上跑，GitHub Actions 每小時）

photo_index.py 算的是「手機也跑得動」的小模型特徵（photo_vecs.vec）。這支另外幫協尋案件和收容所毛孩的照片
算一個大很多的模型（DINOv2-large），而且先真的去背（狗貓以外塗成灰色）再算，存進 photo_vecs.vec2。
資料庫比對時兩個分數合起來用（migration v1.97 的 photo_score2）。實測（scripts/photo_eval5*.py，113 張考題）：
第 1 名就找對 69% → 81%，前 5 名 86% → 94%。

環境變數：SUPABASE_URL、SUPABASE_SERVICE_KEY；SHARD＝"0/4"（分工）；BUDGET_SEC；
加參數 --count 只印出還有幾張沒算（不載入模型）。
"""
import os, sys, time
from concurrent.futures import ThreadPoolExecutor
from photo_match import sb, sb_all, note, fetch_img

T0 = time.time(); BUDGET = int(os.environ.get("BUDGET_SEC", "2100"))
SHARD = os.environ.get("SHARD", "0/1")
GREY = (124, 116, 104)

def todo():
    a, b = map(int, SHARD.split("/"))
    rows = sb_all("photo_vecs?vec2=is.null&ver=eq.2&kind=in.(case,shelter)&select=id,kind,url&order=kind.asc,id.desc")
    return [r for r in rows if "#" not in r["url"] and r["id"] % b == a]

_seg = None
def cutout(crop):
    """去背：狗貓以外的地方塗成灰色，再裁到剛好包住（和 photo_eval5.py 實測時的做法一樣）"""
    global _seg
    import numpy as np
    from PIL import Image
    from rembg import new_session, remove
    if _seg is None: _seg = new_session("isnet-general-use")
    k = 512 / max(crop.size)
    im = crop.resize((max(8, round(crop.size[0] * k)), max(8, round(crop.size[1] * k))), Image.BICUBIC) if k < 1 else crop
    m = remove(im, session=_seg, only_mask=True).convert("L")
    a = np.asarray(m); ys, xs = np.where(a > 100)
    if len(xs) < 0.03 * a.size: return crop
    out = Image.composite(im, Image.new("RGB", im.size, GREY), m)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    s = max(x1 - x0, y1 - y0); l, t = (x0 + x1) / 2 - s / 2, (y0 + y1) / 2 - s / 2
    bg = Image.new("RGB", (int(s), int(s)), GREY)
    bg.paste(out.crop((int(max(0, l)), int(max(0, t)), int(min(im.size[0], l + s)), int(min(im.size[1], t + s)))), (int(max(0, -l)), int(max(0, -t))))
    return bg

def main():
    rows = todo()
    if "--count" in sys.argv:
        print(len(rows))
        if os.environ.get("GITHUB_OUTPUT"): open(os.environ["GITHUB_OUTPUT"], "a").write(f"n={len(rows)}\n")
        return
    if not rows: note("大模型照片特徵：沒有新的"); return
    import numpy as np, torch
    from transformers import AutoModel, AutoImageProcessor
    import photo_index as PI
    torch.set_num_threads(4)
    proc = AutoImageProcessor.from_pretrained("facebook/dinov2-large"); model = AutoModel.from_pretrained("facebook/dinov2-large").eval()
    done = fail = 0
    for i in range(0, len(rows), 16):
        if time.time() - T0 > BUDGET: break
        part = rows[i:i + 16]
        with ThreadPoolExecutor(8) as ex: ims = list(ex.map(lambda r: fetch_img(r["url"]), part))
        for r, im in zip(part, ims):
            if im is None: fail += 1; continue
            try:
                crop = PI.crop_pet(im.convert("RGB"))
                try: cut = cutout(crop)
                except Exception as e: print("去背失敗", str(e)[:80], flush=True); cut = crop
                x = proc(images=cut, return_tensors="pt", size={"height": 224, "width": 224}, do_center_crop=False)
                with torch.no_grad(): v = model(pixel_values=x["pixel_values"]).last_hidden_state[0, 0].numpy().astype(np.float32)
                v = v / (np.linalg.norm(v) + 1e-9)
                sb("PATCH", f"photo_vecs?id=eq.{r['id']}", {"vec2": PI.vec_str(v)}, "return=minimal"); done += 1
            except Exception as e:
                fail += 1; print("skip", r["id"], str(e)[:120], flush=True)
        if done and (i // 16) % 10 == 0: print("…", done, int(time.time() - T0), "s", flush=True)
    note(f"大模型照片特徵（第 {SHARD} 份）：這次算 {done} 張，失敗 {fail}，還沒算 {max(0, len(rows) - done - fail)}")

if __name__ == "__main__":
    import traceback, urllib.error
    try: main()
    except urllib.error.HTTPError as e:
        body = e.read()[:400].decode("utf-8", "replace").replace("\n", " ")
        print(f"::error::HTTP {e.code} {e.url[:120]} {body}", flush=True); raise SystemExit(1)
    except Exception:
        print("::error::" + traceback.format_exc().replace("\n", " | ")[-900:], flush=True); raise SystemExit(1)

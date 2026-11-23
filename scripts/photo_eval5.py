#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""汪喵回家 — 照片比對準確度實測（第五輪）：真的去背（把狗貓以外的地方塗灰）＋更大的模型＋兩個模型合起來。
這一輪找的是「放在主機上跑」的做法（案件照片和收容所照片都是排程算的，不用受手機限制）。手動執行。"""
import os, time, random, itertools
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from PIL import Image
from photo_match import sb_all, fetch_img
import photo_index as PI
import photo_eval as E

N_SHELTER = int(os.environ.get("N_SHELTER", "600"))
MODELS = [m for m in os.environ.get("MODELS", "").split(",") if m]      # 只跑這幾個（分工用）；空的＝全部
SLICE = os.environ.get("SLICE", "")                                     # "0/3"＝只算第 0 份（共 3 份）
OUT = os.environ.get("OUT", "")                                         # 有設就把向量存檔，之後合起來算
GREY = (124, 116, 104)
def n(v): return v / (np.linalg.norm(v) + 1e-9)

_seg = None
def cutout(crop):
    """把框好的照片再去背：狗貓以外的地方塗成灰色，再裁到剛好包住"""
    global _seg
    from rembg import new_session, remove
    if _seg is None: _seg = new_session("isnet-general-use")
    k = 512 / max(crop.size)
    im = crop.resize((max(8, round(crop.size[0] * k)), max(8, round(crop.size[1] * k))), Image.BICUBIC) if k < 1 else crop
    m = remove(im, session=_seg, only_mask=True).convert("L")
    a = np.asarray(m)
    ys, xs = np.where(a > 100)
    if len(xs) < 0.03 * a.size: return crop      # 幾乎沒切到東西：用原本的
    out = Image.composite(im, Image.new("RGB", im.size, GREY), m)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    s = max(x1 - x0, y1 - y0); l, t = (x0 + x1) / 2 - s / 2, (y0 + y1) / 2 - s / 2
    bg = Image.new("RGB", (int(s), int(s)), GREY)
    bg.paste(out.crop((int(max(0, l)), int(max(0, t)), int(min(im.size[0], l + s)), int(min(im.size[1], t + s)))), (int(max(0, -l)), int(max(0, -t))))
    return bg

def load_models():
    import torch
    from transformers import AutoModel, AutoImageProcessor
    torch.set_num_threads(4)
    M = {}
    def hf(name, dino=False):
        proc = AutoImageProcessor.from_pretrained(name); m = AutoModel.from_pretrained(name).eval()
        def f(im):
            kw = dict(size={"height": 224, "width": 224}, do_center_crop=False) if dino else {}
            x = proc(images=im, return_tensors="pt", **kw)
            with torch.no_grad():
                if hasattr(m, "get_image_features"):
                    v = m.get_image_features(pixel_values=x["pixel_values"])
                    if not torch.is_tensor(v): v = v.pooler_output
                    v = v[0]
                else: v = m(pixel_values=x["pixel_values"]).last_hidden_state[0, 0]
            return n(v.numpy().astype(np.float32))
        return f
    for tag, name, dino in (("DINOv2-base", "facebook/dinov2-base", True), ("DINOv2-large", "facebook/dinov2-large", True),
                            ("DINOv2-large-reg", "facebook/dinov2-with-registers-large", True),
                            ("SigLIP2-base", "google/siglip2-base-patch16-224", False), ("SigLIP2-large", "google/siglip2-large-patch16-256", False),
                            ("CLIP-L", "openai/clip-vit-large-patch14", False)):
        if MODELS and tag not in MODELS: continue
        try: M[tag] = hf(name, dino); print("載入", tag, flush=True)
        except Exception as e: print("載入失敗", tag, str(e)[:200], flush=True)
    return M
SEG_FOR = {"DINOv2-base", "DINOv2-large", "SigLIP2-base", "SigLIP2-large"}

def main():
    random.seed(7)
    cs = [c for c in sb_all("cases?hidden=eq.false&select=id,species,photos&order=created_at.desc") if len([u for u in (c.get("photos") or []) if u]) >= 2]
    try: pets = [p for p in sb_all("pets?select=id,photos") if len([u for u in (p.get("photos") or []) if u]) >= 2]
    except Exception as e: pets = []; print("pets 讀不到", str(e)[:100])
    w, _ = PI.wanted()
    sh = [k for k in w if k[0] == "shelter"]; random.shuffle(sh); sh = sh[:N_SHELTER]
    ids = {c["id"] for c in cs}; items = []
    for c in cs:
        for u in [u for u in c["photos"] if u][:4]: items.append((c["id"], u))
    for p in pets:
        for u in [u for u in p["photos"] if u][:4]: items.append(("p" + p["id"], u))
    for k in sh: items.append(("s" + k[1], k[2]))
    seen = set()
    for k in w:
        if k[0] == "case" and k[1] not in ids and k[1] not in seen: seen.add(k[1]); items.append(("c" + k[1], k[2]))
    print(f"考題：案件 {len(cs)} 隻、會員毛孩 {len(pets)} 隻有 2 張以上照片；干擾：收容所 {len(sh)}、其他案件 {len(seen)}", flush=True)
    if SLICE:
        a, b = map(int, SLICE.split("/")); items = [it for i, it in enumerate(items) if i % b == a]; print("這一份", len(items), "張", flush=True)
    with ThreadPoolExecutor(8) as ex: ims = list(ex.map(lambda it: fetch_img(it[1]), items))
    M = load_models()
    need_cut = (not MODELS) or any(t in SEG_FOR for t in M) or "q8" in MODELS
    G, V, base, U = [], {}, [], []
    for (g, u), im in zip(items, ims):
        if im is None: continue
        try:
            im = im.convert("RGB")
            crop, ok = E.crop_det(im, "yolox_tiny.onnx", 0.0)
            b = n(E.toks(E.r224(crop))[0])
            if not OUT and base and float((np.stack(base) @ b).max()) > 0.97: continue
            cut = crop
            if need_cut:
                try: cut = cutout(crop)
                except Exception as e: print("去背失敗", str(e)[:80])
            vs = {"現在（q8，只框不去背）": b}
            if need_cut and (not MODELS or "q8" in MODELS): vs["q8 去背"] = n(E.toks(E.r224(cut))[0])
            for tag, f in M.items():
                vs[tag] = f(crop)
                if tag in SEG_FOR: vs[tag + " 去背"] = f(cut)
        except Exception as e: print("skip", str(e)[:100]); continue
        base.append(b); G.append(g); U.append(u)
        for k, v in vs.items(): V.setdefault(k, []).append(v)
        if len(G) % 100 == 0: print("…", len(G), int(time.time() - PI.T0), "s", flush=True)
    if OUT:
        np.savez_compressed(OUT, G=np.array(G), U=np.array(U), **{"v%d" % i: np.stack(v) for i, v in enumerate(V.values())}, names=np.array(list(V.keys())))
        print("已存", OUT, len(G), "張", list(V.keys()), flush=True); return
    G = np.array(G); qi = [i for i, g in enumerate(G) if (G == g).sum() >= 2]
    print(f"實際算出 {len(G)} 張（已去掉重複照片），考題照片 {len(qi)} 張，共 {len(set(G[qi]))} 隻\n")
    SIM = {}
    for name, vs in V.items():
        if len(vs) != len(G): print("==", name, "資料不齊，略過"); continue
        Mx = np.stack(vs); S = Mx @ Mx.T; np.fill_diagonal(S, -1); SIM[name] = S
    def measure(S):
        ranks, pos, neg = [], [], []
        for i in qi:
            same = (G == G[i]); same[i] = False
            bp = S[i][same].max(); other = ~same; other[i] = False
            ranks.append(int((S[i][other] > bp).sum()) + 1); pos.append(bp); neg.append(S[i][other].max())
        ranks = np.array(ranks); pos = np.array(pos); neg = np.array(neg)
        t10, t5 = float(np.quantile(neg, .9)), float(np.quantile(neg, .95))
        return dict(r1=100 * (ranks == 1).mean(), r3=100 * (ranks <= 3).mean(), r5=100 * (ranks <= 5).mean(), r10=100 * (ranks <= 10).mean(),
                    a10=100 * (pos >= t10).mean(), a5=100 * (pos >= t5).mean(), t10=t10, t5=t5, pm=float(np.median(pos)), nm=float(np.median(neg)))
    def show(name, r):
        print(f"== {name}")
        print(f"   第 1 名就找對 {r['r1']:.0f}%　前 3 名 {r['r3']:.0f}%　前 5 名 {r['r5']:.0f}%　前 10 名 {r['r10']:.0f}%")
        print(f"   不同隻誤認 10% 時認出 {r['a10']:.0f}%（門檻 {r['t10']:.3f}）；誤認 5% 時 {r['a5']:.0f}%（門檻 {r['t5']:.3f}）；同一隻中位 {r['pm']:.3f}，不同隻最像的中位 {r['nm']:.3f}", flush=True)
    for name, S in SIM.items(): show(name, measure(S))
    # 兩個合起來（各自標準化後相加）
    def z(S):
        o = S[~np.eye(len(S), dtype=bool)]; return (S - o.mean()) / (o.std() + 1e-9)
    pairs = []
    for a, b in itertools.combinations(SIM, 2):
        pairs.append((a + " ＋ " + b, measure(z(SIM[a]) + z(SIM[b]))))
    pairs.sort(key=lambda p: -(p[1]["a5"] + p[1]["a10"] + p[1]["r1"]))
    print("\n—— 兩個合起來，最好的 10 組 ——")
    for name, r in pairs[:10]: show(name, r)
if __name__ == "__main__":
    main()

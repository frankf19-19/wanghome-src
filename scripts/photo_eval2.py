#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""汪喵回家 — 照片比對準確度實測（第二輪）：比較不同的 AI 模型（都先偵測出狗貓再裁切）。手動執行。"""
import os, time, random, traceback
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from PIL import Image
from photo_match import sb_all, fetch_img
import photo_index as PI
import photo_eval as E

N_SHELTER = int(os.environ.get("N_SHELTER", "900"))
def n(v): return v / (np.linalg.norm(v) + 1e-9)

def load_models():
    import torch, timm
    from transformers import AutoModel
    torch.set_num_threads(4)
    M = {}
    def dino(name):
        m = AutoModel.from_pretrained(name).eval()
        mean = torch.tensor(PI.MEAN).view(1, 3, 1, 1); std = torch.tensor(PI.STD).view(1, 3, 1, 1)
        def f(im):
            x = torch.from_numpy(np.asarray(im.resize((224, 224), Image.BICUBIC), dtype=np.float32) / 255).permute(2, 0, 1)[None]
            with torch.no_grad(): h = m(pixel_values=(x - mean) / std).last_hidden_state[0].numpy()
            return {"CLS": n(h[0]), "CLS+平均": n(n(h[0]) + n(h[1:].mean(0)))}
        return f
    def tm(name):
        m = timm.create_model(name, pretrained=True, num_classes=0).eval()
        cfg = timm.data.resolve_model_data_config(m); tf = timm.data.create_transform(**cfg, is_training=False)
        def f(im):
            with torch.no_grad(): v = m(tf(im)[None])[0].numpy()
            return {"": n(v)}
        return f
    for tag, fn, arg in (("DINOv2-small 原版", dino, "facebook/dinov2-small"), ("DINOv2-base", dino, "facebook/dinov2-base"),
                         ("MegaDescriptor-T", tm, "hf-hub:BVRA/MegaDescriptor-T-224"), ("MegaDescriptor-B", tm, "hf-hub:BVRA/MegaDescriptor-B-224"),
                         ("MegaDescriptor-L", tm, "hf-hub:BVRA/MegaDescriptor-L-384"), ("MiewID", None, None)):
        if fn is None: continue
        try: M[tag] = fn(arg); print("載入", tag, flush=True)
        except Exception as e: print("載入失敗", tag, str(e)[:200], flush=True)
    return M

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
    with ThreadPoolExecutor(8) as ex: ims = list(ex.map(lambda it: fetch_img(it[1]), items))
    M = load_models()
    G, V, base = [], {}, []
    for (g, u), im in zip(items, ims):
        if im is None: continue
        try:
            crop, ok = E.crop_det(im, "yolox_tiny.onnx", 0.0)
            c, _ = E.toks(E.r224(crop)); b = n(c)
            # 一模一樣的照片（重複登記）不拿來當考題或干擾
            if base and float((np.stack(base) @ b).max()) > 0.97: continue
            vs = {"目前的手機模型（q8）": b}
            for tag, f in M.items():
                for sub, v in f(crop).items(): vs[tag + (" " + sub if sub else "")] = v
        except Exception as e: print("skip", str(e)[:100]); continue
        base.append(b); G.append(g)
        for k, v in vs.items(): V.setdefault(k, []).append(v)
        if len(G) % 150 == 0: print("…", len(G), int(time.time() - PI.T0), "s", flush=True)
    G = np.array(G); qi = [i for i, g in enumerate(G) if (G == g).sum() >= 2]
    print(f"實際算出 {len(G)} 張（已去掉重複照片），考題照片 {len(qi)} 張，共 {len(set(G[qi]))} 隻\n")
    for name, vs in V.items():
        if len(vs) != len(G): print("==", name, "資料不齊，略過"); continue
        Mx = np.stack(vs); Sim = Mx @ Mx.T; np.fill_diagonal(Sim, -1)
        ranks, pos, neg = [], [], []
        for i in qi:
            same = (G == G[i]); same[i] = False
            bp = Sim[i][same].max(); other = ~same; other[i] = False
            ranks.append(int((Sim[i][other] > bp).sum()) + 1); pos.append(bp); neg.append(Sim[i][other].max())
        ranks = np.array(ranks); pos = np.array(pos); neg = np.array(neg)
        print(f"== {name}")
        print(f"   第 1 名就找對 {100 * (ranks == 1).mean():.0f}%　前 3 名 {100 * (ranks <= 3).mean():.0f}%　前 5 名 {100 * (ranks <= 5).mean():.0f}%　前 10 名 {100 * (ranks <= 10).mean():.0f}%　平均名次 {ranks.mean():.1f}")
        print(f"   同一隻：10%={np.quantile(pos, .1):.2f} 中位={np.median(pos):.2f}；不同隻最像的：中位={np.median(neg):.2f} 90%={np.quantile(neg, .9):.2f}")
        t = float(np.quantile(neg, .9))
        print(f"   門檻 {t:.2f}（不同隻誤認 10%）：同一隻被認出 {100 * (pos >= t).mean():.0f}%", flush=True)
if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
汪喵回家 — 照片比對準確度實測（手動執行）
拿「同一隻毛孩有兩張以上照片」的案件當考題：用其中一張去找，看另一張排第幾名；
干擾項是其他案件的照片和收容所的照片。比較幾種算特徵的方法，找出最準的。
"""
import os, json, time, random
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from PIL import Image
from photo_match import sb_all, fetch_img, note
import photo_index as PI

N_SHELTER = int(os.environ.get("N_SHELTER", "700"))
MEAN, STD = PI.MEAN, PI.STD
import onnxruntime as ort
S = ort.InferenceSession(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ai", "dinov2s-q8.onnx"), providers=["CPUExecutionProvider"])
def n(v): return v / (np.linalg.norm(v) + 1e-9)
def toks(im224):
    x = ((np.asarray(im224, dtype=np.float32) / 255 - MEAN) / STD).transpose(2, 0, 1)[None]
    h = S.run(None, {"pixel_values": x})[0][0]
    return h[0], h[1:]
def center(im):
    w, h = im.size; s = min(w, h)
    return im.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s))
def letter(im):
    w, h = im.size; s = max(w, h); bg = Image.new("RGB", (s, s), (124, 116, 104)); bg.paste(im, ((s - w) // 2, (s - h) // 2)); return bg
def r224(im): return im.resize((224, 224), Image.BICUBIC)
from photo_detect import detect
DET = os.environ.get("DET_DIR", "/tmp/det")
def crop_det(im, model, pad):
    r = detect(im, os.path.join(DET, model))
    if not r or r[0][0] < 0.3: return center(im), False
    _, _, x0, y0, x1, y1 = r[0]; w, h = im.size; s = max(x1 - x0, y1 - y0) * (1 + 2 * pad); cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    l, t = cx - s / 2, cy - s / 2
    bg = Image.new("RGB", (max(8, int(s)), max(8, int(s))), (124, 116, 104))
    bg.paste(im.crop((int(max(0, l)), int(max(0, t)), int(min(w, l + s)), int(min(h, t + s)))), (int(max(0, -l)), int(max(0, -t))))
    return bg, True
HIT = {"nano": 0, "tiny": 0, "n": 0}
def variants(im):
    out = {}
    c, _ = toks(r224(center(im))); out["A 目前（置中裁切）"] = n(c)
    HIT["n"] += 1
    for tag, model in (("nano", "yolox_nano.onnx"), ("tiny", "yolox_tiny.onnx")):
        f0, ok = crop_det(im, model, 0.0); HIT[tag] += ok
        c0, _ = toks(r224(f0)); out[f"{tag} 偵測出狗貓再裁切"] = n(c0)
        f1, _ = crop_det(im, model, 0.1); c1, _ = toks(r224(f1)); out[f"{tag} 裁切留一點邊"] = n(c1)
        c2, _ = toks(r224(f0).transpose(Image.FLIP_LEFT_RIGHT)); out[f"{tag} 裁切+左右翻轉"] = n(n(c0) + n(c2))
        out[f"{tag} 裁切+原圖"] = n(n(c0) + n(c))
    return out

def main():
    random.seed(7)
    cs = [c for c in sb_all("cases?hidden=eq.false&select=id,species,photos&order=created_at.desc") if len([u for u in (c.get("photos") or []) if u]) >= 2]
    w, ok = PI.wanted()
    sh = [k for k in w if k[0] == "shelter"]; random.shuffle(sh); sh = sh[:N_SHELTER]
    single = [k for k in w if k[0] == "case" and k[1] not in {c["id"] for c in cs}][:300]
    items = []   # (group, url)
    for c in cs:
        for u in [u for u in c["photos"] if u][:3]: items.append((c["id"], u))
    for k in sh: items.append(("s" + k[1], k[2]))
    seen = set()
    for k in single:
        if k[1] in seen: continue
        seen.add(k[1]); items.append(("c" + k[1], k[2]))
    print(f"考題：{len(cs)} 隻毛孩有 2 張以上照片；干擾照片：收容所 {len(sh)}、其他案件 {len(seen)}", flush=True)
    with ThreadPoolExecutor(8) as ex: ims = list(ex.map(lambda it: fetch_img(it[1]), items))
    G, V = [], {}
    for (g, u), im in zip(items, ims):
        if im is None: continue
        try: vs = variants(im)
        except Exception as e: print("skip", str(e)[:80]); continue
        G.append(g)
        for k, v in vs.items(): V.setdefault(k, []).append(v)
        if len(G) % 200 == 0: print("…", len(G), int(time.time() - PI.T0), "s", flush=True)
    G = np.array(G); qi = [i for i, g in enumerate(G) if (G == g).sum() >= 2]
    print(f"實際算出 {len(G)} 張，考題照片 {len(qi)} 張；偵測到狗貓：nano {HIT['nano']}/{HIT['n']}，tiny {HIT['tiny']}/{HIT['n']}\n")
    for name, vs in V.items():
        M = np.stack(vs); Sim = M @ M.T; np.fill_diagonal(Sim, -1)
        ranks, pos, neg = [], [], []
        for i in qi:
            same = (G == G[i]); same[i] = False
            bp = Sim[i][same].max(); bn = Sim[i][~same & (np.arange(len(G)) != i)].max()
            ranks.append(int((Sim[i][~same] > bp).sum()) + 1); pos.append(bp); neg.append(bn)
        ranks = np.array(ranks); pos = np.array(pos); neg = np.array(neg)
        print(f"== {name}")
        print(f"   第 1 名就找對 {100 * (ranks == 1).mean():.0f}%　前 5 名內 {100 * (ranks <= 5).mean():.0f}%　前 10 名內 {100 * (ranks <= 10).mean():.0f}%　名次中位數 {int(np.median(ranks))}")
        print(f"   同一隻的相似度：10%={np.quantile(pos, .1):.2f} 中位={np.median(pos):.2f}；不同隻最像的：中位={np.median(neg):.2f} 90%={np.quantile(neg, .9):.2f} 99%={np.quantile(neg, .99):.2f}")
        best = max(((100 * (pos >= t).mean() - 100 * (neg >= t).mean(), t) for t in np.arange(.3, .9, .02)))
        for t in (best[1], float(np.quantile(neg, .95))):
            print(f"   門檻 {t:.2f}：同一隻被認出 {100 * (pos >= t).mean():.0f}%，不同隻被誤認 {100 * (neg >= t).mean():.0f}%")
if __name__ == "__main__":
    main()

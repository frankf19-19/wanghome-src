#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""汪喵回家 — 照片比對準確度實測（第四輪）：第二階段「細看」重新排名。
先用整體特徵（CLS）找出前 30 名，再比對局部特徵（256 個小區塊各自找最像的區塊，看斑紋、臉部細節），
看看把兩種分數合起來，同一隻會不會排得更前面、分數拉得更開。手動執行。"""
import os, time, random, hashlib
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from PIL import Image
from photo_match import sb_all, fetch_img
import photo_index as PI
import photo_eval3 as E3

N_SHELTER = int(os.environ.get("N_SHELTER", "900"))
def n(v): return v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-9)

def tokens(im):
    x = ((np.asarray(im.resize((224, 224), Image.BICUBIC), dtype=np.float32) / 255 - PI.MEAN) / PI.STD).transpose(2, 0, 1)[None]
    h = E3._emb.run(None, {"pixel_values": x})[0][0]
    return n(h[0]), n(h[1:]).astype(np.float16)

def main():
    random.seed(7)
    cs = [c for c in sb_all("cases?hidden=eq.false&select=id,species,photos&order=created_at.desc") if len([u for u in (c.get("photos") or []) if u]) >= 2]
    w, ok = PI.wanted()
    sh = [k for k in w if k[0] == "shelter"]; random.shuffle(sh); sh = sh[:N_SHELTER]
    single = [k for k in w if k[0] == "case" and k[1] not in {c["id"] for c in cs}][:300]
    items = []
    for c in cs:
        for u in [u for u in c["photos"] if u][:4]: items.append((c["id"], u))
    for k in sh: items.append(("s" + k[1], k[2]))
    seen = set()
    for k in single:
        if k[1] in seen: continue
        seen.add(k[1]); items.append(("c" + k[1], k[2]))
    print(f"考題：{len(cs)} 隻毛孩有 2 張以上照片；干擾照片 {len(sh) + len(seen)}", flush=True)
    with ThreadPoolExecutor(8) as ex: ims = list(ex.map(lambda it: fetch_img(it[1]), items))
    G, H, C, P = [], [], [], []
    for (g, u), im in zip(items, ims):
        if im is None: continue
        try:
            im = im.convert("RGB"); k = 640 / max(im.size)
            if k < 1: im = im.resize((round(im.size[0] * k), round(im.size[1] * k)), Image.BICUBIC)
            bs = E3.boxes(im); cls, pt = tokens(E3.sq(im, bs[0] if bs else None))
            C.append(cls); P.append(pt); G.append(g); H.append(hashlib.md5(np.asarray(im.resize((16, 16)).convert("L")).tobytes()).hexdigest())
        except Exception as e: print("skip", str(e)[:80]); continue
    G = np.array(G); H = np.array(H); C = np.stack(C); N = len(G)
    S = C @ C.T; np.fill_diagonal(S, -1)
    qi = [i for i in range(N) if (G == G[i]).sum() >= 2]
    print(f"實際算出 {N} 張，考題 {len(qi)} 張", flush=True)
    K = 30
    def patch(i, j):
        M = P[i].astype(np.float32) @ P[j].astype(np.float32).T      # 256×256
        a = M.max(1); b = M.max(0)
        mut = (M.argmax(1)[M.argmax(0)] == np.arange(256))          # 互相最像的區塊
        return float((a.mean() + b.mean()) / 2), float(mut.mean())
    res = {}
    for i in qi:
        top = np.argsort(-S[i])[:K]
        res[i] = [(j, S[i, j], *patch(i, j)) for j in top]
    def report(name, f):
        ranks, pos, neg = [], [], []
        for i in qi:
            same = (G == G[i]); dup = (H == H[i]) & ~same
            sc = [(f(c, p, m), j) for j, c, p, m in res[i]]
            sp = [s for s, j in sc if same[j] and j != i]; sn = [s for s, j in sc if not same[j] and not dup[j] and j != i]
            if not sp: ranks.append(K + 1); pos.append(-9); neg.append(max(sn) if sn else -9); continue
            bp = max(sp); ranks.append(sum(1 for s in sn if s > bp) + 1); pos.append(bp); neg.append(max(sn) if sn else -9)
        ranks, pos, neg = np.array(ranks), np.array(pos), np.array(neg)
        t10 = float(np.quantile(neg, .9)); t5 = float(np.quantile(neg, .95))
        print(f"== {name}")
        print(f"   第 1 名就找對 {100 * (ranks == 1).mean():.0f}%　前 3 名 {100 * (ranks <= 3).mean():.0f}%　前 5 名 {100 * (ranks <= 5).mean():.0f}%")
        print(f"   不同隻誤認 10% 時，同一隻被認出 {100 * (pos >= t10).mean():.0f}%；誤認 5% 時 {100 * (pos >= t5).mean():.0f}%", flush=True)
    report("只看整體（現在）", lambda c, p, m: c)
    report("只看局部", lambda c, p, m: p)
    report("只看互相最像的區塊比例", lambda c, p, m: m)
    for a in (0.3, 0.5, 0.7):
        report(f"整體×{a}＋局部×{1 - a:.1f}", lambda c, p, m, a=a: a * c + (1 - a) * p)
        report(f"整體×{a}＋互相比例×{1 - a:.1f}", lambda c, p, m, a=a: a * c + (1 - a) * m)
if __name__ == "__main__":
    main()

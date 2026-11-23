#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""汪喵回家 — 第五輪實測的合併：把分工算好的向量檔（vec-*/vec.npz）合起來，算每種做法和兩兩合起來的準確度。"""
import sys, glob, itertools
import numpy as np
BASE = "現在（q8，只框不去背）"
def main():
    D, Gm, order = {}, {}, []
    for f in sorted(glob.glob(sys.argv[1] + "/**/*.npz", recursive=True)):
        z = np.load(f, allow_pickle=False); names = [str(x) for x in z["names"]]
        for j, u in enumerate(z["U"]):
            u = str(u)
            if u not in D: D[u] = {}; order.append(u)
            Gm[u] = str(z["G"][j])
            for i, nm in enumerate(names): D[u][nm] = z["v%d" % i][j]
    allnames = sorted({k for d in D.values() for k in d}, key=lambda k: (k != BASE, k))
    us = [u for u in order if len(D[u]) == len(allnames)]
    print(f"向量檔合計 {len(D)} 張，每種做法都有的 {len(us)} 張；做法：{allnames}")
    keep, base = [], []
    for u in us:
        b = D[u][BASE]
        if base and float((np.stack(base) @ b).max()) > 0.97: continue
        base.append(b); keep.append(u)
    G = np.array([Gm[u] for u in keep]); qi = [i for i, g in enumerate(G) if (G == g).sum() >= 2]
    print(f"去掉重複照片後 {len(G)} 張，考題照片 {len(qi)} 張，共 {len(set(G[qi]))} 隻\n")
    SIM = {}
    for nm in allnames:
        Mx = np.stack([D[u][nm] for u in keep]); S = Mx @ Mx.T; np.fill_diagonal(S, -1); SIM[nm] = S
    def measure(S):
        ranks, pos, neg = [], [], []
        for i in qi:
            same = (G == G[i]); same[i] = False
            bp = S[i][same].max(); other = ~same; other[i] = False
            ranks.append(int((S[i][other] > bp).sum()) + 1); pos.append(bp); neg.append(S[i][other].max())
        ranks = np.array(ranks); pos = np.array(pos); neg = np.array(neg)
        t10, t5 = float(np.quantile(neg, .9)), float(np.quantile(neg, .95))
        return dict(r1=100 * (ranks == 1).mean(), r3=100 * (ranks <= 3).mean(), r5=100 * (ranks <= 5).mean(), r10=100 * (ranks <= 10).mean(),
                    a10=100 * (pos >= t10).mean(), a5=100 * (pos >= t5).mean(), t10=t10, t5=t5, pm=float(np.median(pos)), nm=float(np.median(neg)),
                    p25=float(np.quantile(pos, .25)), n75=float(np.quantile(neg, .75)))
    def show(name, r):
        print(f"== {name}")
        print(f"   第1名 {r['r1']:.0f}%　前3 {r['r3']:.0f}%　前5 {r['r5']:.0f}%　前10 {r['r10']:.0f}%　｜誤認10%時認出 {r['a10']:.0f}%（門檻 {r['t10']:.3f}）　誤認5%時 {r['a5']:.0f}%（門檻 {r['t5']:.3f}）")
        print(f"   同一隻：中位 {r['pm']:.3f}、較差的四分之一 {r['p25']:.3f}　不同隻最像的：中位 {r['nm']:.3f}、較高的四分之一 {r['n75']:.3f}", flush=True)
    for nm, S in SIM.items(): show(nm, measure(S))
    rng0 = np.random.default_rng(3)
    def z(S):
        o = S[~np.eye(len(S), dtype=bool)]; return (S - o.mean()) / (o.std() + 1e-9)
    Z = {k: z(S) for k, S in SIM.items()}
    key = lambda p: -(p[1]["a5"] + p[1]["a10"] + p[1]["r1"] + p[1]["r5"])
    for k in (2, 3):
        res = [(" ＋ ".join(c), measure(sum(Z[a] for a in c))) for c in itertools.combinations(SIM, k)]
        res.sort(key=key); print(f"\n—— {k} 個合起來，最好的 10 組 ——")
        for name, r in res[:10]: show(name, r)
    # 上線要用的算法：先用現在的模型取前 50 名，再用「現在＋大模型去背」重新排名；順便印出標準化用的常數
    A, B = BASE, "DINOv2-large 去背"
    if B in SIM:
        for k in (A, B):
            o = SIM[k][~np.eye(len(G), dtype=bool)]; print(f"常數 {k}: mean={o.mean():.4f} std={o.std():.4f}")
        for wB in (0.5, 1.0, 1.5, 2.0):
            C = Z[A] + wB * Z[B]; R = np.full_like(C, -99.0)
            for i in range(len(G)):
                top = np.argsort(-SIM[A][i])[:50]; R[i, top] = C[i, top]
            show(f"上線算法（前 50 名重排，大模型權重 {wB}）", measure(R)); show(f"　　不限前 50 名，權重 {wB}", measure(C))
        v = []
        C = Z[A] + Z[B]
        for _ in range(200):
            sub = rng0.choice(qi, len(qi), replace=True); d = 0
            for i in sub:
                same = (G == G[i]); same[i] = False; other = ~same; other[i] = False
                d += int(C[i][other].max() < C[i][same].max()) - int(SIM[A][i][other].max() < SIM[A][i][same].max())
            v.append(100 * d / len(sub))
        print(f"合起來比現在多找對的比例（第1名）：{np.quantile(v, .05):.0f}～{np.quantile(v, .95):.0f} 個百分點")
    # 穩不穩：隨機抽八成考題重算 200 次，看第 1 名比例的範圍
    rng = np.random.default_rng(1); print("\n—— 第1名比例的起伏範圍（抽樣 200 次的 5%～95%）——")
    full = qi[:]
    def r1(S, sub):
        ok = 0
        for i in sub:
            same = (G == G[i]); same[i] = False; other = ~same; other[i] = False
            ok += S[i][other].max() < S[i][same].max()
        return 100 * ok / len(sub)
    for nm, S in SIM.items():
        v = [r1(S, rng.choice(full, len(full), replace=True)) for _ in range(200)]
        print(f"   {nm}: {np.quantile(v, .05):.0f}%～{np.quantile(v, .95):.0f}%")
if __name__ == "__main__":
    main()

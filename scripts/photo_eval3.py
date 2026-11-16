#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""汪喵回家 — 照片比對準確度實測（第三輪）：
  A 現在的做法：每張照片只框一隻狗／貓
  B 多框：每張照片最多框 4 隻（海報常有好幾張照片），兩張照片的相似度取「任兩個框」最像的
  C 毛色檢查：框內的毛色分布差太多就扣分（減少黑狗配到白狗）
  D 多框＋毛色
同一張照片重複出現在不同案件（例如農業部和本站各一筆）不算「不同隻」。手動執行。"""
import os, time, random, hashlib
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from PIL import Image
from photo_match import sb_all, fetch_img
import photo_index as PI
import onnxruntime as ort

N_SHELTER = int(os.environ.get("N_SHELTER", "900"))
DET = os.path.join(PI.AI_DIR, "yolox_nano.onnx")
_det = ort.InferenceSession(DET, providers=["CPUExecutionProvider"])
_emb = ort.InferenceSession(os.path.join(PI.AI_DIR, "dinov2s-q8.onnx"), providers=["CPUExecutionProvider"])
def n(v): return v / (np.linalg.norm(v) + 1e-9)

def boxes(im, size=416, k=4):
    w, h = im.size; r = min(size / w, size / h); nw, nh = int(w * r), int(h * r)
    c = np.full((size, size, 3), 114, dtype=np.float32); c[:nh, :nw] = np.asarray(im.resize((nw, nh), Image.BILINEAR), dtype=np.float32)[:, :, ::-1]
    out = _det.run(None, {"images": c.transpose(2, 0, 1)[None]})[0][0]
    g, st = [], []
    for s in (8, 16, 32):
        m = size // s; yy, xx = np.mgrid[0:m, 0:m]; g.append(np.stack([xx, yy], -1).reshape(-1, 2)); st.append(np.full((m * m, 1), s))
    g = np.concatenate(g); st = np.concatenate(st)
    xy = (out[:, :2] + g) * st; wh = np.exp(out[:, 2:4]) * st
    sc = out[:, 4:5] * out[:, 5:]
    cand = []
    for cl in (15, 16, 17, 18, 19, 21):
        s = sc[:, cl] * (1 if cl in (15, 16) else .6)
        for i in np.where(s > 0.3)[0]:
            x, y = xy[i] / r; bw, bh = wh[i] / r
            cand.append((float(s[i]), cl, max(0, x - bw / 2), max(0, y - bh / 2), min(w, x + bw / 2), min(h, y + bh / 2)))
    cand.sort(reverse=True); keep = []
    def iou(a, b):
        ix = max(0, min(a[4], b[4]) - max(a[2], b[2])); iy = max(0, min(a[5], b[5]) - max(a[3], b[3])); inter = ix * iy
        return inter / ((a[4] - a[2]) * (a[5] - a[3]) + (b[4] - b[2]) * (b[5] - b[3]) - inter + 1e-9)
    for c_ in cand:
        if (c_[4] - c_[2]) * (c_[5] - c_[3]) < 0.02 * w * h: continue          # 太小的不要（海報上的小圖示）
        if all(iou(c_, kk) < 0.45 for kk in keep): keep.append(c_)
        if len(keep) >= k: break
    return keep

def sq(im, b):
    w, h = im.size
    if b is None:
        s = min(w, h); return im.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s))
    _, _, x0, y0, x1, y1 = b; s = max(x1 - x0, y1 - y0, 8); l, t = (x0 + x1) / 2 - s / 2, (y0 + y1) / 2 - s / 2
    bg = Image.new("RGB", (int(round(s)), int(round(s))), (124, 116, 104))
    bg.paste(im.crop((int(round(max(0, l))), int(round(max(0, t))), int(round(min(w, l + s))), int(round(min(h, t + s))))), (int(round(max(0, -l))), int(round(max(0, -t)))))
    return bg

def emb(im):
    x = ((np.asarray(im.resize((224, 224), Image.BICUBIC), dtype=np.float32) / 255 - PI.MEAN) / PI.STD).transpose(2, 0, 1)[None]
    return n(_emb.run(None, {"pixel_values": x})[0][0][0])

def colour(im, b):
    """框內中間 60% 的毛色：12 格的顏色直方圖（灰階 4 格＋彩色 8 個色相），用來粗略比對毛色"""
    w, h = im.size
    if b is None: x0, y0, x1, y1 = 0, 0, w, h
    else: _, _, x0, y0, x1, y1 = b
    cx, cy, bw, bh = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) * .6, (y1 - y0) * .6
    a = np.asarray(im.crop((int(cx - bw / 2), int(cy - bh / 2), int(cx + bw / 2), int(cy + bh / 2))).convert("HSV").resize((48, 48)), dtype=np.float32) / 255
    H, S, V = a[..., 0].ravel(), a[..., 1].ravel(), a[..., 2].ravel()
    hist = np.zeros(12)
    grey = S < 0.22
    for i, (lo, hi) in enumerate(((0, .25), (.25, .5), (.5, .75), (.75, 1.01))): hist[i] = ((grey) & (V >= lo) & (V < hi)).sum()
    hb = np.minimum((H[~grey] * 8).astype(int), 7)
    for i in range(8): hist[4 + i] = (hb == i).sum()
    hist[4:] *= 0.8
    return hist / (hist.sum() + 1e-9)

def feats(im):
    bs = boxes(im)
    one = bs[0] if bs else None
    f = {"A": [emb(sq(im, one))], "cA": [colour(im, one)]}
    multi = bs if bs else [None]
    f["B"] = [emb(sq(im, b)) for b in multi]; f["cB"] = [colour(im, b) for b in multi]
    f["nb"] = len(bs)
    return f

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
    print(f"考題：{len(cs)} 隻毛孩有 2 張以上照片；干擾照片：收容所 {len(sh)}、其他案件 {len(seen)}", flush=True)
    with ThreadPoolExecutor(8) as ex: ims = list(ex.map(lambda it: fetch_img(it[1]), items))
    G, H, F = [], [], []
    for (g, u), im in zip(items, ims):
        if im is None: continue
        try:
            im = im.convert("RGB"); k = 640 / max(im.size)
            if k < 1: im = im.resize((round(im.size[0] * k), round(im.size[1] * k)), Image.BICUBIC)
            F.append(feats(im)); G.append(g); H.append(hashlib.md5(np.asarray(im.resize((16, 16)).convert("L")).tobytes()).hexdigest())
        except Exception as e: print("skip", str(e)[:80]); continue
        if len(G) % 200 == 0: print("…", len(G), int(time.time() - PI.T0), "s", flush=True)
    G = np.array(G); H = np.array(H); N = len(G)
    multi = sum(1 for f in F if f["nb"] >= 2)
    print(f"實際算出 {N} 張；框到 2 隻以上的照片 {multi} 張\n", flush=True)
    def simmat(key):
        S = np.full((N, N), -1.0)
        for i in range(N):
            Ei = np.stack(F[i][key])
            for j in range(i + 1, N):
                s = float((Ei @ np.stack(F[j][key]).T).max()); S[i, j] = S[j, i] = s
        return S
    def colmat(key, ekey):
        D = np.zeros((N, N))
        for i in range(N):
            for j in range(i + 1, N):
                Ei, Ej = np.stack(F[i][ekey]), np.stack(F[j][ekey]); a, b = np.unravel_index(int((Ei @ Ej.T).argmax()), (len(Ei), len(Ej)))
                d = 0.5 * np.abs(F[i][key][a] - F[j][key][b]).sum(); D[i, j] = D[j, i] = d
        return D
    SA, SB = simmat("A"), simmat("B")
    DA, DB = colmat("cA", "A"), colmat("cB", "B")
    qi = [i for i in range(N) if (G == G[i]).sum() >= 2]
    def report(name, S):
        ranks, pos, neg = [], [], []
        for i in qi:
            same = (G == G[i]); same[i] = False
            dup = (H == H[i]) & ~same; dup[i] = False                     # 同一張照片出現在別的案件：不算不同隻
            other = ~same & ~dup & (np.arange(N) != i)
            bp = S[i][same].max(); bn = S[i][other].max()
            ranks.append(int((S[i][other] > bp).sum()) + 1); pos.append(bp); neg.append(bn)
        ranks, pos, neg = np.array(ranks), np.array(pos), np.array(neg)
        t10 = float(np.quantile(neg, .9)); t5 = float(np.quantile(neg, .95))
        print(f"== {name}")
        print(f"   第 1 名就找對 {100 * (ranks == 1).mean():.0f}%　前 3 名 {100 * (ranks <= 3).mean():.0f}%　前 5 名 {100 * (ranks <= 5).mean():.0f}%")
        print(f"   不同隻誤認 10% 時，同一隻被認出 {100 * (pos >= t10).mean():.0f}%（門檻 {t10:.2f}）；誤認 5% 時 {100 * (pos >= t5).mean():.0f}%（門檻 {t5:.2f}）", flush=True)
    report("A 現在：只框一隻", SA)
    report("B 多框", SB)
    for lam in (0.15, 0.25, 0.35):
        report(f"C 毛色扣分 λ={lam}", SA - lam * DA)
        report(f"D 多框＋毛色 λ={lam}", SB - lam * DB)
if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""把全台灣 OpenStreetMap 的公園、遊樂場、狗狗公園、飲水站整理成散步冒險的補給站。
輸出 osm/st/<格子>.json（0.05 度一格，約 5.5 公里）：[[id,種類,緯度,經度,名稱],...]
用法：python3 build_tw.py taiwan-latest.osm.pbf osm/st
"""
import sys, os, json, math
import osmium

STEP = 0.05
def kind(tags):
    le = tags.get('leisure'); am = tags.get('amenity')
    if le == 'dog_park': return 'dog_park'
    if le == 'playground': return 'playground'
    if le == 'park': return 'park'
    if am == 'drinking_water': return 'water'
    return None

class H(osmium.SimpleHandler):
    def __init__(s):
        super().__init__(); s.out = []
    def add(s, oid, k, lat, lon, tags):
        if not (21.5 < lat < 26.5 and 118 < lon < 122.5): return
        s.out.append([oid, k, round(lat, 6), round(lon, 6), (tags.get('name') or '')[:20]])
    def node(s, n):
        k = kind(n.tags)
        if k and n.location.valid(): s.add('n%d' % n.id, k, n.location.lat, n.location.lon, n.tags)
    def area(s, a):
        k = kind(a.tags)
        if not k: return
        xs = ys = c = 0
        for ring in a.outer_rings():
            for nd in ring:
                if nd.location.valid(): ys += nd.location.lat; xs += nd.location.lon; c += 1
        if c: s.add(('w%d' if a.from_way() else 'r%d') % a.orig_id(), k, ys / c, xs / c, a.tags)

def main(pbf, outdir):
    h = H(); h.apply_file(pbf, locations=True)
    os.makedirs(outdir, exist_ok=True)
    for f in os.listdir(outdir):
        if f.endswith('.json'): os.remove(os.path.join(outdir, f))
    buckets = {}
    for r in h.out:
        key = '%d_%d' % (math.floor(r[2] / STEP), math.floor(r[3] / STEP))
        buckets.setdefault(key, []).append(r)
    for key, rows in buckets.items():
        with open(os.path.join(outdir, key + '.json'), 'w', encoding='utf-8') as fh:
            json.dump(rows, fh, ensure_ascii=False, separators=(',', ':'))
    cnt = {}
    for r in h.out: cnt[r[1]] = cnt.get(r[1], 0) + 1
    print('stations', len(h.out), cnt, 'files', len(buckets))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

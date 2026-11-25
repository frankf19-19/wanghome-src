# 汪喵回家 — 網友協尋案件自動做 Reel（9:16, 約 25 秒）＋貼文海報（1080x1350）
# 用法：python3 auto_reel.py case.json outdir
#   case.json：cases 的欄位（name, species, sex, age_text, breed, colour, features, collar_desc, has_chip,
#              lost_at, lost_city, lost_district, lost_place, contact_name, contact_phone(只有公開才給), id）
#              另外 photos_local：已下載的照片路徑（1~3 張）
# 輸出：outdir/reel.mp4、outdir/poster.jpg
# 規則：不用「牠」，用男生／女生；電話單獨一行＋稱呼；不編造資料；每次配色、版型、音樂隨機，不會每則都一樣。
import json, os, random, re, subprocess, sys
from datetime import datetime, timedelta, timezone
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CJK = '/usr/share/fonts/opentype/noto/NotoSansCJK-{}.ttc'
def F(sz, w='Bold'):
    for x in (w, 'Bold', 'Regular'):
        if os.path.exists(CJK.format(x)): return ImageFont.truetype(CJK.format(x), sz, index=3)
    raise OSError('找不到 Noto Sans CJK 字型')
def NUM(sz):
    for p in ['/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf']:
        if os.path.exists(p): return ImageFont.truetype(p, sz)
    return F(sz, 'Black')
W, H = 1080, 1920
ICON = Image.open(os.path.join(ROOT, 'icon-512.png')).convert('RGBA')

# ---------- 配色（底色、主色、強調、文字、淡字、卡片、膠帶）
PALETTES = [
    dict(bg=(236,229,216), main=(86,104,74),  acc=(170,72,50),  ink=(48,36,28),  mut=(120,106,92), card=(252,248,240), tape=(224,196,120,170)),
    dict(bg=(232,238,243), main=(44,72,110),  acc=(226,120,64), ink=(28,36,48),  mut=(96,110,128), card=(255,255,255), tape=(250,214,120,170)),
    dict(bg=(247,236,228), main=(196,92,74),  acc=(60,92,84),   ink=(52,34,30),  mut=(130,104,96), card=(255,251,247), tape=(160,200,190,170)),
    dict(bg=(240,240,232), main=(58,58,58),   acc=(230,170,40), ink=(30,30,30),  mut=(110,110,104),card=(255,255,250), tape=(240,200,90,180)),
    dict(bg=(234,242,232), main=(64,120,90),  acc=(214,96,110), ink=(30,48,40),  mut=(100,124,110),card=(252,255,250), tape=(240,180,190,170)),
    dict(bg=(244,238,250), main=(104,80,150), acc=(236,140,60), ink=(40,32,56),  mut=(118,106,136),card=(255,253,255), tape=(200,220,150,170)),
]

def cover(im, w, h, fx=.5, fy=.4):
    im = im.convert('RGB'); s = max(w / im.width, h / im.height)
    im = im.resize((max(w, round(im.width * s)), max(h, round(im.height * s))), Image.LANCZOS)
    l = int((im.width - w) * fx); t = int((im.height - h) * fy)
    return im.crop((l, t, l + w, t + h)).convert('RGBA')

def wrap(d, text, font, width, maxlines=3):
    out, line = [], ''
    for ch in text:
        if d.textlength(line + ch, font=font) > width:
            out.append(line); line = ch
            if len(out) == maxlines: break
        else: line += ch
    if len(out) < maxlines and line: out.append(line)
    if len(out) == maxlines and ''.join(out) != text: out[-1] = out[-1][:-1] + '…'
    return out

def fit(d, text, w, start, minsz=28, weight='Black'):
    sz = start
    while sz > minsz and d.textlength(text, font=F(sz, weight)) > w: sz -= 2
    return F(sz, weight)

def shadowed(card, rot):
    sh = Image.new('RGBA', (card.width + 40, card.height + 40), (0, 0, 0, 0))
    m = Image.new('L', sh.size, 0); ImageDraw.Draw(m).rounded_rectangle([20, 26, card.width + 20, card.height + 26], radius=18, fill=80)
    sh.paste((40, 30, 20, 255), (0, 0), m.filter(ImageFilter.GaussianBlur(12))); sh.alpha_composite(card, (20, 20))
    return sh.rotate(rot, expand=True, resample=Image.BICUBIC) if rot else sh

def photo_card(P, im, w, h, style, rot, cap=None, capf=None, fy=.35):
    if style == 'polaroid':
        pad = 26; capH = ((capf.size if capf else 52) + 50) if cap else pad
        card = Image.new('RGBA', (w + pad * 2, h + pad + capH), P['card'] + (255,)); card.alpha_composite(cover(im, w, h, .5, fy), (pad, pad))
        if cap:
            d = ImageDraw.Draw(card); f = capf or F(52, 'Black'); d.text(((card.width - d.textlength(cap, font=f)) / 2, h + pad + 18), cap, font=f, fill=P['ink'])
        sh = shadowed(card, 0)
        t = Image.new('RGBA', (190, 52), P['tape']); sh.alpha_composite(t.rotate(random.choice([-8, 6]), expand=True), (sh.width // 2 - 105, 0))
        return sh.rotate(rot, expand=True, resample=Image.BICUBIC)
    # rounded：圓角照片＋白框
    pad = 14; card = Image.new('RGBA', (w + pad * 2, h + pad * 2 + (((capf.size if capf else 52) + 46) if cap else 0)), (0, 0, 0, 0))
    ImageDraw.Draw(card).rounded_rectangle([0, 0, card.width - 1, card.height - 1], radius=40, fill=P['card'] + (255,))
    ph = cover(im, w, h, .5, fy); m = Image.new('L', (w, h), 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=30, fill=255); ph.putalpha(m)
    card.alpha_composite(ph, (pad, pad))
    if cap:
        d = ImageDraw.Draw(card); f = capf or F(52, 'Black'); d.text(((card.width - d.textlength(cap, font=f)) / 2, h + pad + 6), cap, font=f, fill=P['ink'])
    return shadowed(card, rot)

def foot(img, col):
    d = ImageDraw.Draw(img); a = ICON.resize((48, 48)); t = '汪喵回家｜幫忙集中協尋的力量'; f = F(30, 'Medium')
    tw = d.textlength(t, font=f) + 60; x = int((img.width - tw) / 2); y = img.height - 110; img.paste(a, (x, y), a); d.text((x + 60, y + 6), t, font=f, fill=col)

def light(c): return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) > 160
def on(c, P): return P['ink'] if light(c) else P['card']
def ctext(d, y, t, f, col, w): d.text(((w - d.textlength(t, font=f)) / 2, y), t, font=f, fill=col)

# ---------- 文字資料（全部來自案件欄位，不編造）
def tw_time(iso):
    t = datetime.fromisoformat(iso.replace('Z', '+00:00')).astimezone(timezone(timedelta(hours=8)))
    if t.minute == 0 and t.hour in (0, 12): return f'{t.month}/{t.day}'
    part = '凌晨' if t.hour < 5 else '上午' if t.hour < 12 else '中午' if t.hour < 13 else '下午' if t.hour < 18 else '晚上'
    hh = t.hour - 12 if t.hour > 12 else t.hour
    return f'{t.month}/{t.day} {part}約 {hh} 點' + (f'{t.minute} 分' if t.minute else '')

def phone_fmt(p):
    d = re.sub(r'\D', '', p or '').replace('886', '0', 1) if (p or '').startswith(('+886', '886')) else re.sub(r'\D', '', p or '')
    return f'{d[:4]}-{d[4:7]}-{d[7:]}' if re.fullmatch(r'09\d{8}', d) else (p or '').strip()

def scrub(s):
    s = re.sub(r'(\+?886|0)9\d{2}[-\s]?\d{3}[-\s]?\d{3}', '', s or '')
    s = re.sub(r'[\w.+-]+@[\w-]+\.[\w.]+', '', s)
    return re.sub(r'(line|賴)\s*(id)?\s*[:：]?\s*@?[\w.-]{3,}', '', s, flags=re.I).strip()

def facts(c):
    name = (c.get('name') or '').strip()[:10]
    kid = '男生' if c.get('sex') == 'male' else '女生' if c.get('sex') == 'female' else ('貓咪' if c.get('species') == 'cat' else '狗狗')
    who = f"{(c.get('age_text') or '')[:8] + '的' if c.get('age_text') else ''}{(c.get('breed') or '')[:10]}{kid}"
    area = (c.get('lost_city') or '').replace('臺', '台') + (c.get('lost_district') or '')
    place = scrub(c.get('lost_place') or '')[:16]
    cn = (c.get('contact_name') or '').strip()[:8]
    call = cn if cn and cn not in ('飼主', '主人', '我', '本人', '家人') else f'{name}家人'
    notes = []
    if c.get('breed') or c.get('sex') in ('male', 'female'): notes.append(((c.get('breed') or ('貓咪' if c.get('species') == 'cat' else '狗狗'))[:9] + ('・' + kid if kid in ('男生', '女生') else ''), (c.get('age_text') or '')[:12]))
    if c.get('colour'): notes.append((scrub(c['colour'])[:9], '毛色'))
    if c.get('has_chip'): notes.append(('有晶片', '收容所掃得到'))
    feat = scrub(c.get('features') or c.get('collar_desc') or '')
    if feat and len(notes) < 3: notes.append((feat[:9], feat[9:22] if len(feat) > 9 else '特徵'))
    return dict(name=name, kid=kid, who=who, area=area, place=place, when=tw_time(c['lost_at']), call=call,
                phone=phone_fmt(c.get('contact_phone')) if c.get('contact_phone') else '', notes=notes[:3],
                cat=c.get('species') == 'cat')

# ---------- 場景
def scenes(c, photos, out, P, style):
    f = facts(c); n = f['name']; p1 = photos[0]; p2 = photos[1] if len(photos) > 1 else photos[0]; p3 = photos[2] if len(photos) > 2 else p1
    Y = {}
    # A：地點＋大照片＋找某某
    b = Image.new('RGBA', (W, H), P['bg'] + (255,)); d = ImageDraw.Draw(b)
    d.text((80, 150), f['area'] + (' ' + f['place'] if f['place'] else ''), font=fit(d, f['area'] + ' ' + f['place'], 920, 50, 30, 'Bold'), fill=P['main']); foot(b, P['mut'])
    b.convert('RGB').save(f'{out}/a_bg.png')
    fg = Image.new('RGBA', (980, 1380), (0, 0, 0, 0)); pl = photo_card(P, p1, 760, 900, style, random.choice([-3, 2, 0]), f'找{n}', F(84, 'Black'))
    fg.alpha_composite(pl, ((980 - pl.width) // 2, 0)); fd = ImageDraw.Draw(fg)
    line = f"{f['who']}・{f['when']}走失"; ctext(fd, 1250, line, fit(fd, line, 940, 42, 28, 'Bold'), P['acc'], 980)
    fg.save(f'{out}/a_fg.png'); Y['a'] = 280
    # B：某某的樣子（便條＋第二張照片）
    b = Image.new('RGBA', (W, H), P['main'] + (255,)); d = ImageDraw.Draw(b)
    d.text((80, 150), f'{n}的樣子', font=fit(d, f'{n}的樣子', 920, 96), fill=on(P['main'], P)); foot(b, on(P['main'], P)); b.convert('RGB').save(f'{out}/b_bg.png')
    fg = Image.new('RGBA', (960, 1300), (0, 0, 0, 0)); fd = ImageDraw.Draw(fg)
    pl = photo_card(P, p2, 380, 520, style, 4, None); fg.alpha_composite(pl, (540, 0))
    cols = [(246, 226, 170), P['card'], (240, 206, 190)]
    for i, (k, v) in enumerate(f['notes'] or [(f['who'][:9], '')]):
        y = 20 + i * 220; fd.rounded_rectangle([0, y, 500, y + 180], radius=18, fill=cols[i % 3])
        fd.text((34, y + 26), k, font=fit(fd, k, 440, 52), fill=P['ink'])
        if v: fd.text((36, y + 100), v, font=fit(fd, v, 440, 34, 24, 'Medium'), fill=P['mut'])
    fg.alpha_composite(photo_card(P, p3, 520, 560, style, -2, None, fy=.25), (200, 700)); fg.save(f'{out}/b_fg.png'); Y['b'] = 330
    # C：看到的話
    b = Image.new('RGBA', (W, H), P['bg'] + (255,)); d = ImageDraw.Draw(b)
    d.text((80, 150), f'看到{n}的話', font=fit(d, f'看到{n}的話', 920, 96), fill=P['ink']); foot(b, P['mut']); b.convert('RGB').save(f'{out}/c_bg.png')
    fg = Image.new('RGBA', (940, 1260), (0, 0, 0, 0)); fd = ImageDraw.Draw(fg)
    steps = random.choice([
        [('不要叫、不要追', '容易受驚，越追越遠'), ('先拍照、記下地點', '時間和方向都很有用'), ('聯絡家人', '或到汪喵回家留下線索')],
        [('慢慢靠近就好', '大聲叫反而會跑走'), ('拍照留下證據', '記下時間、地點、往哪走'), ('告訴家人', '電話或汪喵回家都可以')],
    ])
    for i, (k, v) in enumerate(steps):
        y = i * 250; fd.rounded_rectangle([0, y, 940, y + 210], radius=28, fill=P['card']); fd.ellipse([36, y + 55, 136, y + 155], fill=P['acc'] if i == 2 else P['main'])
        fd.text((86 - fd.textlength(str(i + 1), font=NUM(56)) / 2, y + 70), str(i + 1), font=NUM(56), fill=P['card'])
        fd.text((170, y + 40), k, font=F(58, 'Black'), fill=P['ink']); fd.text((172, y + 120), v, font=F(36, 'Medium'), fill=P['mut'])
    fg.alpha_composite(photo_card(P, p1, 420, 420, style, 3, None, fy=.2), (250, 770)); fg.save(f'{out}/c_fg.png'); Y['c'] = 330
    # D：聯絡
    b = Image.new('RGBA', (W, H), P['acc'] + (255,)); d = ImageDraw.Draw(b)
    d.text((80, 150), f'請幫{n}回家', font=fit(d, f'請幫{n}回家', 920, 100), fill=on(P['acc'], P)); foot(b, on(P['acc'], P)); b.convert('RGB').save(f'{out}/d_bg.png')
    fg = Image.new('RGBA', (940, 1160), (0, 0, 0, 0)); fd = ImageDraw.Draw(fg)
    fd.rounded_rectangle([0, 0, 940, 380], radius=30, fill=P['card'])
    fd.text((60, 60), f['call'], font=fit(fd, f['call'], 820, 56), fill=P['acc'])
    if f['phone']: fd.text((60, 160), f['phone'], font=NUM(104) if len(f['phone']) <= 12 else NUM(80), fill=P['ink'])
    else: fd.text((60, 170), '請到汪喵回家回報線索', font=F(64, 'Black'), fill=P['ink'])
    pl = photo_card(P, p2, 440, 440, style, -4, None, fy=.2); fg.alpha_composite(pl, ((940 - pl.width) // 2, 410))
    ctext(fd, 960, '也可以到汪喵回家的案件頁留下線索', F(40, 'Bold'), on(P['acc'], P), 940)
    ctext(fd, 1030, 'App Store 搜尋「汪喵回家」', F(44, 'Black'), on(P['acc'], P), 940); fg.save(f'{out}/d_fg.png'); Y['d'] = 400
    return f, Y

def poster(c, photos, out, P, style, f):
    p = Image.new('RGBA', (1080, 1350), P['bg'] + (255,)); d = ImageDraw.Draw(p)
    d.text((56, 46), f"找{f['name']}", font=fit(d, f"找{f['name']}", 960, 108), fill=P['ink'])
    sub = f"{f['area']} {f['place']}・{f['when']}走失".replace('  ', ' ')
    d.text((60, 190), sub, font=fit(d, sub, 960, 34, 24, 'Bold'), fill=P['main'])
    pl = photo_card(P, photos[0], 540, 680, style, -3, None); p.alpha_composite(pl, (20, 250))
    pl2 = photo_card(P, photos[1] if len(photos) > 1 else photos[0], 250, 300, style, 5, None, fy=.3); p.alpha_composite(pl2, (700, 236))
    cols = [(246, 226, 170), P['card'], (240, 206, 190)]
    for i, (k, v) in enumerate(f['notes'] or [(f['who'][:9], '')]):
        y = 740 + i * 108; d.rounded_rectangle([660, y, 1036, y + 96], radius=14, fill=cols[i % 3])
        d.text((684, y + 10), k, font=fit(d, k, 330, 38), fill=P['ink'])
        if v: d.text((686, y + 58), v, font=fit(d, v, 330, 26, 20, 'Medium'), fill=P['mut'])
    d.rounded_rectangle([50, 1070, 1030, 1262], radius=32, fill=P['acc'])
    t1 = f"看到請打給 {f['call']}" if f['phone'] else f"看到請聯絡 {f['call']}"
    d.text((90, 1090), t1, font=fit(d, t1, 900, 40), fill=on(P['acc'], P))
    if f['phone']: d.text((90, 1150), f['phone'], font=NUM(80), fill=on(P['acc'], P))
    else: d.text((90, 1160), '到汪喵回家回報線索', font=F(64, 'Black'), fill=on(P['acc'], P))
    a = ICON.resize((34, 34)); p.paste(a, (50, 1294), a); d.text((94, 1294), '汪喵回家', font=F(26, 'Medium'), fill=P['mut'])
    t = 'App Store 搜尋「汪喵回家」'; d.text((1030 - d.textlength(t, font=F(26, 'Medium')), 1294), t, font=F(26, 'Medium'), fill=P['mut'])
    p.convert('RGB').save(f'{out}/poster.jpg', quality=90)

def encode(out, Y, music):
    durs = {'a': 6.4, 'b': 6.4, 'c': 6.5, 'd': 6.2}
    for k, dur in durs.items():
        n = int(dur * 30); fh = Image.open(f'{out}/{k}_fg.png').height
        flt = (f"[1:v]format=rgba,scale=w='trunc(iw*(1+0.05*t/{dur})/2)*2':h=-2:eval=frame[f];"
               f"[0:v][f]overlay=x='(W-w)/2':y='{Y[k]}+({fh}-h)/2':eval=frame:format=auto,format=yuv420p,"
               f"fade=t=in:st=0:d=0.6,fade=t=out:st={dur - 0.5}:d=0.5")
        subprocess.run(['ffmpeg', '-y', '-v', 'error', '-framerate', '30', '-loop', '1', '-t', str(dur), '-i', f'{out}/{k}_bg.png',
                        '-framerate', '30', '-loop', '1', '-t', str(dur), '-i', f'{out}/{k}_fg.png', '-filter_complex', flt,
                        '-frames:v', str(n), '-c:v', 'libx264', '-crf', '21', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', '-r', '30', f'{out}/{k}.tmp.mp4'], check=True)
        os.replace(f'{out}/{k}.tmp.mp4', f'{out}/{k}.mp4')
    with open(f'{out}/list.txt', 'w') as fh: fh.write(''.join(f"file '{k}.mp4'\n" for k in durs))
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-f', 'concat', '-safe', '0', '-i', f'{out}/list.txt', '-c', 'copy', f'{out}/v.mp4'], check=True)
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', f'{out}/v.mp4', '-i', music, '-map', '0:v', '-map', '1:a', '-c:v', 'copy',
                    '-af', 'volume=0.8', '-c:a', 'aac', '-b:a', '128k', '-shortest', '-movflags', '+faststart', f'{out}/reel.tmp.mp4'], check=True)
    os.replace(f'{out}/reel.tmp.mp4', f'{out}/reel.mp4')

def main():
    c = json.load(open(sys.argv[1])); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
    rnd = random.Random(c.get('id') or None); random.seed(rnd.random())
    photos = [ImageOps.exif_transpose(Image.open(p)) for p in c['photos_local'][:3]]
    P = random.choice(PALETTES); style = random.choice(['polaroid', 'rounded'])
    f, Y = scenes(c, photos, out, P, style)
    poster(c, photos, out, P, style, f)
    mus = sorted(os.listdir(os.path.join(HERE, 'music'))); music = os.path.join(HERE, 'music', random.choice(mus))
    encode(out, Y, music)
    print(json.dumps({'ok': True, 'style': style, 'music': os.path.basename(music)}))

if __name__ == '__main__':
    main()

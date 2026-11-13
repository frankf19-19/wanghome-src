// wangmiaotw.com/app
//   iPhone / iPad：直接帶到 App Store（IG、海報、口頭分享用的短網址，好記好打）
//   其他裝置和搜尋引擎：App 介紹頁（搜「汪喵回家 app」「尋狗 app」「走失協尋 app」找得到；電腦上可以掃 QR Code）
const STORE = "https://apps.apple.com/tw/app/id6827632980";
const SITE = "https://wangmiaotw.com/";
const NAME = "汪喵回家";
const TITLE = "汪喵回家 App｜尋狗、尋貓、走失協尋 App（免費）iPhone 下載";
const DESC = "汪喵回家是免費的狗貓走失協尋 App：登記走失自動產生協尋海報、附近的人收到通知、每天比對全台收容所、目擊回報畫在地圖上、用照片找相似的毛孩。不收費、不抽獎金。";
const FEATURES = [
  ["🐾", "走失了，三分鐘登記協尋", "填好特徵和走失地點，自動產生有 QR Code 的協尋海報和貼文，直接分享到 LINE、Facebook。"],
  ["🔔", "附近的人會收到通知", "住在走失地點附近、有開通知的使用者會收到推播，出門時幫忙多看一眼。"],
  ["🏠", "每天自動比對全台收容所", "公立收容所新進的狗貓，每天和你的毛孩比對，有相似的就通知你，不用自己一間一間查。"],
  ["📍", "目擊回報畫在地圖上", "路人掃海報 QR Code 就能回報在哪裡看到，連成移動路線，知道牠往哪個方向走。"],
  ["📷", "用照片找找看", "撿到或看到不認識的毛孩，上傳照片，AI 會從協尋中的毛孩和收容所裡找長得像的。"],
  ["💛", "撿到毛孩、想領養也可以用", "登記拾獲通報幫牠找主人；也能看全台收容所待領養的狗貓。"]];
const FAQ = [
  ["汪喵回家 App 要錢嗎？", "完全免費。登記協尋、收容所比對、海報、通知都不收費，找到毛孩也不抽獎金、不要求匯款。"],
  ["Android 手機可以用嗎？", "可以。Android 請直接用瀏覽器打開 wangmiaotw.com，功能和 App 相同，也能加到主畫面。"],
  ["不下載 App 也能登記走失嗎？", "可以，網站 wangmiaotw.com 就能登記協尋、回報目擊、查收容所。App 多了推播通知，有人回報時會馬上知道。"],
  ["資料會公開嗎？", "協尋頁會公開毛孩的照片、特徵和走失地區，方便大家幫忙找。聯絡電話要不要公開由飼主自己決定。"]];
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const CSS = `:root{--ink:#2B2326;--mute:#6F6468;--red:#B8335A;--bg:#FDF6F8;--line:#EADDE2}*{box-sizing:border-box}body{margin:0;font-family:system-ui,"PingFang TC","Noto Sans TC","Microsoft JhengHei",sans-serif;background:var(--bg);color:var(--ink);line-height:1.65}
a{color:var(--red)}header{display:flex;align-items:center;padding:14px 16px;max-width:980px;margin:0 auto}header a{display:flex;align-items:center;gap:8px;text-decoration:none;color:var(--ink);font-weight:800;font-size:20px}header img{width:34px;height:34px}
main{max-width:980px;margin:0 auto;padding:0 16px 48px}.top{display:grid;gap:24px;align-items:center;padding:12px 0 8px}@media(min-width:800px){.top{grid-template-columns:1.1fr .9fr}}
h1{font-size:34px;line-height:1.25;margin:0 0 12px}.lede{font-size:18px;color:var(--mute);margin:0 0 20px}h2{font-size:22px;margin:40px 0 12px}
.get{display:flex;gap:16px;align-items:center;flex-wrap:wrap}.btn{display:inline-block;background:var(--ink);color:#fff;text-decoration:none;font-weight:800;padding:14px 22px;border-radius:14px;font-size:17px}.btn.web{background:#fff;color:var(--ink);border:1.5px solid var(--line)}
.qr{display:flex;gap:12px;align-items:center;background:#fff;border-radius:16px;padding:10px 14px;font-size:14px;color:var(--mute)}.qr img{width:104px;height:104px;display:block}@media(max-width:799px){.qr{display:none}}
.shots{display:flex;gap:12px;justify-content:center}.shots img{width:31%;max-width:190px;height:auto;border-radius:22px;border:1px solid var(--line);background:#fff}
.fs{display:grid;gap:12px}@media(min-width:700px){.fs{grid-template-columns:1fr 1fr}}.f{background:#fff;border-radius:18px;padding:16px 18px}.f b{display:block;font-size:17px;margin-bottom:2px}.f span{color:var(--mute);font-size:15px}.f i{font-style:normal;margin-right:6px}
details{background:#fff;border-radius:16px;padding:12px 16px;margin-top:8px}summary{font-weight:800;cursor:pointer}details p{margin:8px 0 0}
footer{color:var(--mute);font-size:13px;text-align:center;padding:24px 16px}`;
function page() {
  const jsonld = [
    { "@context": "https://schema.org", "@type": "MobileApplication", name: "汪喵回家：尋狗尋貓・走失協尋", operatingSystem: "iOS", applicationCategory: "LifestyleApplication", url: SITE + "app", installUrl: STORE, downloadUrl: STORE,
      description: DESC, inLanguage: "zh-Hant", image: SITE + "icon-512.png", screenshot: [SITE + "shot-home.jpg", SITE + "shot-case.jpg", SITE + "shot-health.jpg"],
      offers: { "@type": "Offer", price: "0", priceCurrency: "TWD" }, publisher: { "@type": "Organization", name: NAME, url: SITE } },
    { "@context": "https://schema.org", "@type": "FAQPage", mainEntity: FAQ.map(([q, a]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a } })) },
    { "@context": "https://schema.org", "@type": "BreadcrumbList", itemListElement: [{ "@type": "ListItem", position: 1, name: NAME, item: SITE }, { "@type": "ListItem", position: 2, name: "下載 App", item: SITE + "app" }] }];
  return `<!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="apple-itunes-app" content="app-id=6827632980">
<title>${esc(TITLE)}</title><meta name="description" content="${esc(DESC)}"><link rel="canonical" href="${SITE}app"><link rel="icon" href="${SITE}icon.svg" type="image/svg+xml">
<meta property="og:type" content="website"><meta property="og:site_name" content="${NAME}"><meta property="og:title" content="${esc(TITLE)}"><meta property="og:description" content="${esc(DESC)}"><meta property="og:image" content="${SITE}og.png?v=2"><meta property="og:url" content="${SITE}app"><meta property="og:locale" content="zh_TW"><meta name="twitter:card" content="summary_large_image">
<script type="application/ld+json">${JSON.stringify(jsonld).replace(/</g, "\\u003c")}</script><style>${CSS}</style></head><body>
<header><a href="${SITE}"><img src="${SITE}icon.svg" alt="">${NAME}</a></header><main>
<div class="top"><div><h1>汪喵回家 App：毛孩走失了，大家一起找</h1><p class="lede">免費的狗貓走失協尋 App。登記走失、通知附近的人、每天比對全台收容所，找到也不收一毛錢。</p>
<div class="get"><a class="btn" href="${STORE}">在 App Store 下載（iPhone）</a><a class="btn web" href="${SITE}">Android／電腦：直接用網頁版</a></div>
<div class="get" style="margin-top:14px"><div class="qr"><img src="${SITE}app-qr.png" width="104" height="104" alt="汪喵回家 App 下載 QR Code"><span>用 iPhone 相機掃這個碼<br>直接到 App Store 下載</span></div></div></div>
<div class="shots"><img src="${SITE}shot-home.jpg" width="540" height="1080" alt="汪喵回家 App 首頁：附近正在協尋的走失狗貓"><img src="${SITE}shot-case.jpg" width="540" height="1080" alt="汪喵回家 App 協尋頁：走失毛孩的照片、特徵與目擊地圖"><img src="${SITE}shot-health.jpg" width="540" height="1080" alt="汪喵回家 App 毛孩健康紀錄" loading="lazy"></div></div>
<h2>這個 App 可以做什麼</h2><div class="fs">${FEATURES.map(([i, t, d]) => `<div class="f"><b><i>${i}</i>${esc(t)}</b><span>${esc(d)}</span></div>`).join("")}</div>
<h2>常見問題</h2>${FAQ.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join("")}
<h2>毛孩走失了嗎？</h2><p>不用先下載，現在就能<a href="${SITE}#/new">免費登記協尋</a>。也可以先看<a href="${SITE}g/dog-lost">狗走失怎麼辦</a>、<a href="${SITE}g/cat-lost">貓走失怎麼找</a>，或看看<a href="${SITE}l/">各縣市正在協尋的毛孩</a>。</p>
</main><footer>${NAME}｜全台走失狗貓協尋平台・免費・不收手續費<br><a href="${SITE}">回首頁</a>・<a href="${SITE}l/">各縣市走失毛孩</a>・<a href="${SITE}g/">協尋指南</a>・<a href="${SITE}adopt/">領養</a></footer></body></html>`;
}
export const onRequest = ({ request }) => {
  const ua = request.headers.get("User-Agent") || "";
  if (/iPhone|iPad|iPod/i.test(ua) && !/bot|crawl|spider|facebookexternalhit|Line\//i.test(ua))
    return new Response(null, { status: 302, headers: { Location: STORE, "Cache-Control": "no-store", Vary: "User-Agent" } });
  return new Response(page(), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=600", Vary: "User-Agent", "x-content-type-options": "nosniff" } });
};

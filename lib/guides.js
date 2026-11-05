// 汪喵回家 — 協尋指南的靜態頁（給搜尋引擎看，/g/…）
//   /g/              指南總覽
//   /g/<slug>        一篇指南：協尋攻略拆成的文章，以及毛孩小學堂（lib/learn.js，從 index.html 自動抽出）
// 這些頁面是純靜態內容，不讀資料庫；網站內對應的畫面在 #/resources、#/learn/<id>。
import LEARN from "./learn.js";

const SITE = "https://wangmiaotw.com/";
const NAME = "汪喵回家";
const SUPABASE_URL = "https://nopyhfpaykkiieudvoko.supabase.co";
const ANON_KEY = "sb_publishable_WCeVQIAPH0UEEzhTwovqkg_lJ8Qjydb";
const CITIES = ["臺北市","新北市","桃園市","臺中市","臺南市","高雄市","基隆市","新竹市","新竹縣","苗栗縣","彰化縣","南投縣","雲林縣","嘉義市","嘉義縣","屏東縣","宜蘭縣","花蓮縣","臺東縣","澎湖縣","金門縣","連江縣"];
const okImg = (u) => typeof u === "string" && /^https:\/\/nopyhfpaykkiieudvoko\.supabase\.co\/storage\/v1\/object\/public\/photos\/[^\s'"()<>\\]+$/.test(u) ? u : "";
const thumb = (u) => /\.jpg$/.test(u) && !/_t\.jpg$/.test(u) ? u.replace(/\.jpg$/, "_t.jpg") : u;
const days = (ts) => { const a = new Date(new Date(ts).getTime() + 8 * 3600e3), b = new Date(Date.now() + 8 * 3600e3);
  return Math.max(1, Math.round((Date.UTC(b.getUTCFullYear(), b.getUTCMonth(), b.getUTCDate()) - Date.UTC(a.getUTCFullYear(), a.getUTCMonth(), a.getUTCDate())) / 864e5) + 1); };
// 最近登記、有照片的協尋案件（指南頁底部用，把讀文章的人帶去看案件；連不上就不顯示）
async function recentCases(n = 8) {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/cases_public?status=eq.searching&photos=not.eq.%7B%7D&select=id,name,lost_city,lost_district,lost_at,photos&order=last_activity.desc&limit=${n}`,
      { headers: { apikey: ANON_KEY, Accept: "application/json" }, cf: { cacheTtl: 300 } });
    return r.ok ? await r.json() : [];
  } catch (_) { return []; }
}
const caseItem = (c) => { const ph = okImg((c.photos || [])[0]);
  return `<a class="pc" href="${SITE}p/${c.id}">${ph ? `<img loading="lazy" src="${esc(thumb(ph))}" alt="${esc(c.name)}">` : ""}<b>${esc(c.name)}</b><small>${esc((c.lost_city || "") + (c.lost_district || ""))}・走失第 ${days(c.lost_at)} 天</small></a>`; };
const cityNav = () => `<nav class="cities">${CITIES.map((x) => `<a href="${SITE}l/${encodeURIComponent(x)}">${x}</a>`).join("")}</nav>`;
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const strip = (s) => String(s ?? "").replace(/<[^>]+>/g, "");

// ---- 協尋攻略（依台灣飼主實際會搜尋的問題來寫）----
// sec: [標題, [段落或條列]]；字串裡可用 <b>，條列用陣列
const GUIDES = [
  { id: "dog-lost", sp: "dog", ic: "🐕", t: "狗走失了怎麼辦？黃金 48 小時要做的 10 件事", s: "狗狗不見了先別慌，照這個順序做，大部分的狗在 48 小時內找得回來。",
    kw: "狗走失怎麼辦、狗狗不見了、尋狗、找狗、狗跑掉了", faq: [
      ["狗走失多久還找得回來？", "大部分找回的案例發生在 48 小時內，但一兩週後找回的也不少，不要太早放棄。重點是前兩天要把目擊網撒開：登記協尋、貼海報、通知收容所。"],
      ["走失的狗會自己回家嗎？", "有些會，尤其在熟悉的區域。可以把牠的睡墊或你穿過的衣服放在門口和走失點，熟悉的氣味能幫牠定位。"],
      ["要不要報警？", "警察不負責找狗，但如果懷疑被偷或被車撞，可以報案並請里長協助調閱監視器。受傷動物請撥 1959 動保專線。"]],
    sec: [
      ["前 2 小時", [
        "<b>回到走失點附近，安靜地找。</b>膽小、高齡的狗通常躲在走失點 1 公里內的草叢、車底、工地、樓梯間。不要大喊大叫追著跑，受驚的狗會越跑越遠。",
        "<b>把有牠氣味的東西放在走失點</b>：睡墊、你穿過的衣服。清晨 5–7 點和傍晚最容易出來活動。",
        "<b>在汪喵回家免費登記協尋</b>，系統會自動產生有 QR Code 的海報，路人掃了就能直接回報目擊位置。"]],
      ["當天要做完", [
        "<b>打電話給當地動保處和收容所</b>，留下晶片號碼和特徵。被路人送到收容所的狗，飼主常常不知道。汪喵回家會每天自動比對全台收容所，但親自打一通更快。",
        "<b>到農業部寵物登記網做「遺失申報」</b>。動物醫院、收容所掃到晶片時會看到你的申報。",
        "<b>貼到 FB 走失社團和社區 LINE 群</b>。要找走失地點那個「區」的社團，不要只貼全台大社團。用案件頁的「複製協尋貼文」直接貼。"]],
      ["第二天開始", [
        "<b>實體海報貼半徑 2 公里</b>：便利商店、動物醫院、公園、里長辦公室、宮廟、公車站。字要大、電話要大、照片要清楚。",
        "<b>問每天在巷弄跑的人</b>：外送員、郵差、清潔隊、早餐店、大樓保全。他們看到走失狗的機率比任何人高。",
        "<b>請里長協助</b>調閱監視器確認牠往哪個方向跑；鄉下地方宮廟廣播很有效。",
        "<b>附近動物醫院都留資料</b>，撿到狗的人最常先帶去醫院掃晶片。",
        "<b>打 1999 問清潔隊</b>。很殘酷但必要：路殺動物由清潔隊處理，確認一下可以避免白找。"]],
      ["有人說看到牠了", [
        "請對方<b>不要追、不要抓</b>，先拍照、記時間和位置，回報到案件頁。你再帶著牠熟悉的食物和聲音過去。",
        "連續幾個目擊點連成的方向，就是牠移動的路線。汪喵回家的案件頁會把目擊點畫在地圖時間軸上。"]]] },

  { id: "cat-lost", sp: "cat", ic: "🐈", t: "貓走失了怎麼找？室內貓大多躲在家附近", s: "家貓不見了通常沒跑遠，而且會躲起來不出聲。找貓的方法和找狗完全不一樣。",
    kw: "貓走失怎麼找、貓不見了、貓咪跑出去、找貓、尋貓", faq: [
      ["室內貓跑出去會跑多遠？", "大部分躲在家 5 戶範圍內，常見的位置是機車底下、樓梯間、冷氣室外機後面、草叢、地下室。牠會躲好幾天不出來，也不會叫。"],
      ["貓走失幾天還找得到？", "一兩週後找回的很常見。貓會先躲著，餓了才在夜深人靜時出來活動，所以晚上持續去找很重要。"]],
    sec: [
      ["先找這些地方", [
        "<b>家裡先翻一遍</b>：衣櫃深處、床底、洗衣機後面、天花板夾層。很多「走失」的貓其實還在家裡。",
        "<b>家附近 5 戶以內</b>：機車底、樓梯間、冷氣室外機後、花圃草叢、地下停車場、鄰居的陽台和倉庫。請鄰居幫忙開車庫看一下。",
        "<b>往上找也往下找</b>：貓會爬到遮雨棚、鐵皮屋頂，也會掉進排水溝、地下室。"]],
      ["怎麼找才有效", [
        "<b>晚上拿手電筒找</b>。夜深人靜貓才敢動，手電筒照到眼睛會反光，很好認。",
        "<b>輕聲叫名字、搖零食罐、捏響牠熟悉的玩具</b>，然後安靜等一分鐘。不要追、不要大叫。",
        "<b>把貓砂盆和牠的睡墊放在門口</b>，貓砂的氣味可以飄很遠，很多貓是靠這個回家的。",
        "<b>很怕人的貓用誘捕籠</b>。各縣市動保處和 TNR 團體可以借，裡面放牠愛吃的罐頭，晚上放在牠出沒的地方。"]],
      ["同時要做的事", [
        "在汪喵回家登記協尋、通報收容所和動保處、到農業部寵物登記網做遺失申報。",
        "貼社區 LINE 群和 FB 社團，請同棟、同巷的鄰居注意自家車庫和倉庫。",
        "附近動物醫院留資料。撿到貓的人通常會先帶去掃晶片。"]],
      ["找到之後", [
        "貓在外面幾天會脫水、受傷，找回來先給水，帶去動物醫院檢查。",
        "加裝防貓紗窗、窗戶限位器，出門一定用外出籠。貓咪從 2026 年起也要植入晶片登記。"]]] },

  { id: "see-stray", sp: "all", ic: "👀", t: "看到疑似走失的狗貓怎麼辦？不要追，先拍照", s: "路上看到一隻慌張的狗、戴項圈的貓，怎麼做才真的幫到牠。",
    kw: "看到走失狗怎麼辦、路上有狗、流浪狗 走失 分辨、撿到貓", faq: [
      ["怎麼分辨是走失還是流浪？", "有項圈、毛很乾淨、看起來慌張不知所措、在馬路邊來回跑、會靠近人又怕人，多半是剛走失的家犬。長期流浪的狗通常比較鎮定、知道怎麼躲車。"],
      ["可以直接抓牠嗎？", "不要追、不要圍、不要伸手抓。走失的動物處於驚恐狀態，被追會衝到馬路上。先拍照記位置，再試著用食物讓牠自己靠近。"]],
    sec: [
      ["三件事：不追、拍照、回報", [
        "<b>不要追、不要叫、不要圍。</b>走失的狗貓很怕，被追會跑更遠、甚至衝到車道上。",
        "<b>拍照、記下時間、位置、牠往哪個方向走。</b>就算只有背影也有用。",
        "<b>到汪喵回家回報目擊</b>：打開網站看看附近有沒有符合的協尋案件，直接在案件頁回報；找不到的話登記一筆「我看到一隻」，系統會自動比對附近的走失案件，飼主一登記就會看到。"]],
      ["如果牠願意靠近", [
        "側身蹲低、不直視牠、不伸手，可以把食物放在地上退開幾步。",
        "有項圈的話看看有沒有名牌電話，可以試著扣牽繩，但不勉強。",
        "真的抓到了：<b>送附近動物醫院掃晶片</b>（通常免費），或通知當地動保處。"]],
      ["牠受傷了", [
        "撥 <b>1959 動保專線</b>，或 1999 轉動保處。說清楚地點、傷勢、牠還在不在原地。",
        "不要徒手抱，受傷的動物會因為痛咬人；要移動先用外套或毛巾包住。",
        "汪喵回家的「受傷毛孩通報」會自動定位、顯示當地動保單位電話，並產生照著唸的通報稿。"]]] },

  { id: "found-pet", sp: "all", ic: "🙋", t: "撿到狗或貓怎麼辦？先掃晶片，再登記拾獲", s: "撿到毛孩之後，怎麼最快幫牠找到主人，又不會惹上麻煩。",
    kw: "撿到狗怎麼辦、撿到貓怎麼辦、拾獲 寵物、撿到狗 晶片 哪裡掃", faq: [
      ["撿到狗可以自己養嗎？", "依動保法，拾獲的動物應通報或送交動物收容處所，不能直接據為己有。先掃晶片、公告協尋，一段時間都沒人認領，再依各縣市規定辦理認養。"],
      ["掃晶片要去哪裡？要錢嗎？", "任何動物醫院都有晶片掃描器，掃一下通常免費。各縣市動保處和收容所也可以。"]],
    sec: [
      ["第一步：掃晶片", [
        "帶去<b>任何一間動物醫院</b>掃晶片，通常免費。有晶片就能查到飼主，當場就能聯絡。",
        "沒有晶片也請醫院幫忙看一下健康狀況，特別是脫水和外傷。"]],
      ["第二步：登記拾獲，公開協尋", [
        "在汪喵回家登記「<b>我撿到毛孩</b>」：拍正面、側面、特徵（斑點、耳朵、尾巴）的照片。系統會<b>自動比對附近的走失案件</b>，飼主登記協尋時也會看到你的拾獲通報。",
        "通知當地動保處，留下你的聯絡方式和拾獲地點。",
        "貼到拾獲地點那一區的 FB 走失社團和社區 LINE 群。"]],
      ["暫時照顧的注意事項", [
        "和家裡原有的寵物隔離幾天，先確認沒有傳染病和寄生蟲。",
        "給水和少量食物就好，不要一次餵太多。",
        "有人來認領時，<b>請對方提供走失前的照片、晶片資料或特徵描述</b>核對，避免被冒領。"]]] },

  { id: "shelter-search", sp: "all", ic: "🏠", t: "寵物走失後怎麼查收容所？全台收容所查詢方式", s: "被路人送到收容所的狗貓，飼主常常不知道。這篇教你怎麼查、多久查一次。",
    kw: "收容所查詢、走失 收容所、動物收容所 查詢 走失狗、收容所 認領", faq: [
      ["狗被送到收容所會留多久？", "依動保法，收容所收容的動物公告期至少 7 天，期間飼主可以認領。超過期限沒人認領就會開放認養。所以走失後每天都要查。"],
      ["認領要帶什麼？", "身分證、能證明是你的毛孩的資料（寵物登記證、晶片資料、照片）。可能需要補辦寵物登記並繳交收容期間的費用。"]],
    sec: [
      ["去哪裡查", [
        "<b>全國動物收容管理系統</b>（農業部）：全台公立收容所新收容的動物都會公告在這裡，有照片、發現地點、入所日期。",
        "<b>汪喵回家會每天自動比對</b>：你在本站登記協尋後，系統每天用最新的收容所資料和你的案件比對，有疑似的會直接顯示在案件頁。本站的「收容所最近新收」頁面也可以直接看各地新入所的狗貓和被發現的地點。",
        "<b>親自打電話</b>給走失地點所在縣市、以及相鄰縣市的收容所，留晶片號碼和特徵。系統上的照片不一定拍得清楚，電話問最準。"]],
      ["怎麼查比較不會漏", [
        "<b>每天查一次</b>，公告期只有 7 天。",
        "<b>相鄰的縣市也要查</b>：走失的狗可能被人開車載到別的縣市才送收容所。",
        "<b>品種、毛色可能被登記得不一樣</b>：米克斯、混種、黑色、黑褐色……條件放寬一點看。",
        "也查<b>民間收容和動物醫院</b>，有些拾獲者會先送到醫院寄養。"]],
      ["同時也要做遺失申報", [
        "到農業部寵物登記網做「<b>遺失申報</b>」，收容所掃到晶片時會直接看到你的申報，主動聯絡你。",
        "確認寵物登記上的電話是現在在用的號碼。很多找不回來的案例是因為晶片資料的電話早就換了。"]]] },

  { id: "chip-lost-report", sp: "all", ic: "🔖", t: "寵物晶片遺失申報怎麼做？電話沒更新等於沒晶片", s: "走失時晶片是最快找回毛孩的方法，但前提是資料要正確、要申報遺失。",
    kw: "寵物晶片 遺失申報、寵物登記 遺失、晶片查詢 飼主、寵物登記 更改電話", faq: [
      ["晶片可以定位嗎？", "不行。晶片沒有 GPS，只有一組號碼，要被掃描器掃到才能查出飼主。所以走失時還是要靠協尋、海報和收容所比對。"],
      ["沒做寵物登記會怎樣？", "狗和貓依法都要植入晶片做寵物登記，貓從 2026 年起沒登記也會被罰款。更重要的是，沒登記的話掃到晶片也查不到你。"]],
    sec: [
      ["走失當天就做遺失申報", [
        "到<b>農業部寵物登記管理資訊網</b>，用飼主身分登入後做「遺失申報」。",
        "申報後，任何動物醫院或收容所掃到這顆晶片，系統就會標示「遺失中」並顯示你的聯絡方式。",
        "找回來之後記得去取消申報。"]],
      ["平常就要確認的事", [
        "<b>電話有沒有更新</b>：搬家、換號碼一定要去更新寵物登記資料，不然掃到晶片也聯絡不到你。",
        "<b>晶片號碼記下來</b>：可以存在汪喵回家的毛孩健康手冊裡，走失時登記協尋、打電話給收容所都用得到。",
        "<b>另外掛名牌</b>：撿到的人不一定會馬上帶去掃晶片，項圈上有電話最直接。"]]] },
];

const CSS = `:root{--ink:#2B2326;--mute:#6F6468;--red:#B8335A;--bg:#FDF6F8;--card:#fff;--line:#EADDE2}
*{box-sizing:border-box}body{margin:0;font-family:system-ui,"PingFang TC","Noto Sans TC","Microsoft JhengHei",sans-serif;background:var(--bg);color:var(--ink);line-height:1.7}
a{color:var(--red)}header{display:flex;align-items:center;gap:10px;padding:14px 16px;max-width:760px;margin:0 auto}header a{display:flex;align-items:center;gap:8px;text-decoration:none;color:var(--ink);font-weight:800;font-size:18px}header img{width:28px;height:28px}
main{max-width:760px;margin:0 auto;padding:0 16px 40px}h1{font-size:26px;line-height:1.3;margin:8px 0 6px}.lede{color:var(--mute);font-size:17px;margin:0 0 18px}
.sec{background:var(--card);border-radius:20px;padding:16px 18px;margin:12px 0;box-shadow:0 10px 24px -18px rgba(90,30,50,.35)}.sec h2{font-size:19px;margin:0 0 8px}.sec ul{margin:0;padding-left:20px}.sec li{margin:6px 0}
.btn{display:block;text-align:center;background:var(--red);color:#fff;text-decoration:none;font-weight:800;padding:14px;border-radius:16px;margin-top:16px}.btn.ghost{background:#fff;color:var(--ink);border:1.5px solid var(--line)}
.faq{margin-top:22px}.faq h2{font-size:20px}.faq details{background:var(--card);border-radius:14px;padding:10px 16px;margin:8px 0}.faq summary{font-weight:800;cursor:pointer}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px;margin-top:12px}.it{display:flex;gap:10px;align-items:flex-start;text-decoration:none;color:var(--ink);background:var(--card);border-radius:16px;padding:12px 14px}.it .ic{font-size:24px;line-height:1}.it b{display:block;font-size:15px}.it small{color:var(--mute)}
.note{background:#FFF6DC;border-radius:14px;padding:10px 14px;margin-top:16px;font-size:15px}.tag{display:inline-block;background:var(--red);color:#fff;border-radius:99px;padding:2px 10px;font-size:13px;font-weight:800;margin-bottom:8px}
h2.rel{font-size:20px;margin:28px 0 4px}.pcs{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:10px;margin-top:10px}.pc{display:block;text-decoration:none;color:var(--ink);background:var(--card);border-radius:14px;overflow:hidden}.pc img{width:100%;aspect-ratio:1;object-fit:cover;display:block}.pc b{display:block;font-size:14px;padding:8px 10px 0}.pc small{display:block;color:var(--mute);font-size:12px;padding:0 10px 8px}nav.cities{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}nav.cities a{background:#fff;border-radius:99px;padding:6px 12px;text-decoration:none;color:var(--ink);font-size:14px}footer{max-width:760px;margin:0 auto;padding:16px;color:var(--mute);font-size:13px;border-top:1px solid var(--line)}`;

const resp = (body, status = 200, maxAge = 3600) => new Response(body, { status, headers: {
  "content-type": "text/html; charset=utf-8", "cache-control": `public, max-age=${maxAge}`, "x-content-type-options": "nosniff" } });

function shell({ title, desc, canonical, body, jsonld = [], noindex = false }) {
  return `<!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="apple-itunes-app" content="app-id=6827632980">
<title>${esc(title)}</title><meta name="description" content="${esc(desc)}">${noindex ? '<meta name="robots" content="noindex">' : ""}
<link rel="canonical" href="${esc(canonical)}"><link rel="icon" href="${SITE}icon.svg" type="image/svg+xml">
<meta property="og:type" content="article"><meta property="og:site_name" content="${NAME}"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}"><meta property="og:image" content="${SITE}og.png"><meta property="og:url" content="${esc(canonical)}"><meta property="og:locale" content="zh_TW"><meta name="twitter:card" content="summary_large_image">
${jsonld.map((j) => `<script type="application/ld+json">${JSON.stringify(j).replace(/</g, "\\u003c")}</script>`).join("\n")}
<style>${CSS}</style></head><body>
<header><a href="${SITE}"><img src="${SITE}icon.svg" alt="">${NAME}</a></header><main>${body}</main>
<footer>${NAME}｜全台走失狗貓協尋平台・免費・不收手續費<br><a href="${SITE}">回首頁</a>・<a href="${SITE}g/">協尋指南</a>・<a href="${SITE}l/">各縣市走失毛孩</a></footer></body></html>`;
}

const ALL = () => [
  ...GUIDES.map((g) => ({ ...g, kind: "guide" })),
  ...LEARN.map((a) => ({ id: a.id, sp: a.sp, ic: a.ic, t: a.t, s: a.s, kind: "learn", sec: a.b })),
];
export const GUIDE_IDS = () => ALL().map((a) => a.id);

const spName = (sp) => (sp === "dog" ? "狗狗" : sp === "cat" ? "貓咪" : "狗狗・貓咪");
const card = (a) => `<a class="it" href="${SITE}g/${a.id}"><span class="ic">${a.ic || "📘"}</span><span><b>${esc(a.t)}</b><small>${esc(a.s)}</small></span></a>`;
const breadcrumb = (a) => ({ "@context": "https://schema.org", "@type": "BreadcrumbList", itemListElement: [
  { "@type": "ListItem", position: 1, name: NAME, item: SITE },
  { "@type": "ListItem", position: 2, name: "協尋指南", item: `${SITE}g/` },
  { "@type": "ListItem", position: 3, name: a.t, item: `${SITE}g/${a.id}` }] });

export function guideIndex() {
  const all = ALL();
  const g = all.filter((a) => a.kind === "guide"), l = all.filter((a) => a.kind === "learn");
  const title = `協尋指南：狗貓走失怎麼辦、撿到怎麼辦、怎麼查收容所｜${NAME}`;
  const desc = "狗走失怎麼辦、貓走失怎麼找、看到或撿到走失毛孩該怎麼做、收容所怎麼查、晶片遺失申報，以及狗狗貓咪的照顧知識。";
  const body = `<h1>協尋指南</h1><p class="lede">${esc(desc)}</p>
<h2 class="rel">毛孩走失、撿到毛孩</h2><div class="grid">${g.map(card).join("")}</div>
<h2 class="rel">毛孩小學堂</h2><div class="grid">${l.map(card).join("")}</div>
<a class="btn" href="${SITE}#/new">我的毛孩走失了，免費登記協尋</a>`;
  return resp(shell({ title, desc, canonical: `${SITE}g/`, body, jsonld: [{ "@context": "https://schema.org", "@type": "CollectionPage", name: "協尋指南", url: `${SITE}g/`, isPartOf: { "@type": "WebSite", name: NAME, url: SITE } }] }));
}

export async function guidePage(slug) {
  slug = String(slug || "").replace(/\.html$/, "");
  if (!slug) return guideIndex();
  const a = ALL().find((x) => x.id === slug);
  if (!a) return resp(shell({ title: `${NAME}｜找不到這篇`, desc: "", canonical: `${SITE}g/`, body: `<h1>找不到這篇指南</h1><a class="btn" href="${SITE}g/">看全部指南</a>`, noindex: true }), 404, 300);
  const rel = ALL().filter((x) => x.id !== a.id && (x.sp === a.sp || x.sp === "all" || a.sp === "all")).slice(0, 4);
  const title = `${a.t}｜${NAME}`;
  const desc = String(a.s).slice(0, 150);
  const secs = a.sec.map(([h, items]) => `<section class="sec"><h2>${esc(h)}</h2><ul>${items.map((x) => `<li>${x}</li>`).join("")}</ul></section>`).join("");
  const faq = a.faq ? `<div class="faq"><h2>常見問題</h2>${a.faq.map(([q, ans]) => `<details><summary>${esc(q)}</summary><p>${esc(ans)}</p></details>`).join("")}</div>` : "";
  const cta = a.kind === "guide"
    ? (a.id === "found-pet" || a.id === "see-stray" ? `<a class="btn" href="${SITE}#/found/new">我看到／撿到一隻，登記通報</a><a class="btn ghost" href="${SITE}">看附近正在協尋的毛孩</a>` : `<a class="btn" href="${SITE}#/new">我的毛孩走失了，免費登記協尋</a><a class="btn ghost" href="${SITE}l/">看各縣市走失的毛孩</a>`)
    : `<a class="btn ghost" href="${SITE}#/learn/${a.id}">在汪喵回家 App 裡看這篇</a>`;
  const note = a.kind === "learn" ? `<p class="note">這是一般照顧常識，每隻毛孩狀況不同，身體不舒服請以獸醫師的診斷和建議為準。</p>` : "";
  const text = a.sec.map(([h, items]) => h + "。" + items.map(strip).join(" ")).join(" ");
  const jsonld = [
    { "@context": "https://schema.org", "@type": "Article", headline: a.t, description: desc, inLanguage: "zh-Hant", url: `${SITE}g/${a.id}`, image: `${SITE}og.png`,
      author: { "@type": "Organization", name: NAME, url: SITE }, publisher: { "@type": "Organization", name: NAME, logo: { "@type": "ImageObject", url: `${SITE}icon-512.png` } },
      articleBody: text.slice(0, 4000), about: a.kw ? a.kw.split("、") : undefined },
    breadcrumb(a)];
  if (a.faq) jsonld.push({ "@context": "https://schema.org", "@type": "FAQPage", mainEntity: a.faq.map(([q, ans]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: ans } })) });
  const cases = a.kind === "guide" ? await recentCases(8) : [];
  const body = `<span class="tag">${spName(a.sp)}</span><h1>${esc(a.t)}</h1><p class="lede">${esc(a.s)}</p>${secs}${faq}${note}${cta}
${rel.length ? `<h2 class="rel">延伸閱讀</h2><div class="grid">${rel.map(card).join("")}</div>` : ""}
${cases.length ? `<h2 class="rel">現在正在找家的毛孩</h2><p class="lede" style="font-size:15px;margin:0">看到請不要追，拍照記下時間地點，到案件頁回報。</p><div class="pcs">${cases.map(caseItem).join("")}</div>` : ""}
<h2 class="rel">各縣市走失的毛孩</h2>${cityNav()}`;
  return resp(shell({ title, desc, canonical: `${SITE}g/${a.id}`, body, jsonld }));
}

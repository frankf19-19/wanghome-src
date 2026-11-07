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

  { id: "lost-poster", sp: "all", ic: "📄", t: "協尋海報怎麼做？尋狗啟事、尋貓啟事範本與 7 個重點", s: "路人只會看海報兩三秒。照片、電話、走失地點這三樣看清楚了，才有人會回報。",
    kw: "協尋海報、尋狗啟事、尋貓啟事、走失海報範本、協尋海報範本", faq: [
      ["協尋海報要寫懸賞金額嗎？", "可以寫，能讓更多人留意。但要小心詐騙：真的撿到的人不會要你先匯款。交還毛孩前，請對方說出晶片號碼末幾碼、或說出海報上沒寫的特徵。"],
      ["海報要貼多遠？", "先貼走失點半徑 2 公里內：便利商店、動物醫院、公園、公車站、里長辦公室。貓咪走失範圍通常更小，以家附近幾條巷子為主。"],
      ["可以直接用手機做海報嗎？", "可以。在汪喵回家登記協尋後，會自動做好有 QR Code 的協尋海報，有經典、大照片、醒目黃、A4 列印、限時動態幾種版型，存到相簿或傳 LINE 都可以。"]],
    sec: [
      ["一張好海報的 7 個重點", [
        "<b>標題要大</b>：「尋狗啟事」「尋貓啟事」或「走失協尋」，遠遠就看得到。",
        "<b>照片放最大</b>：用最清楚、最像牠平常樣子的照片，能看出毛色和臉型。有兩張就放全身和臉部特寫各一張。",
        "<b>電話放大</b>：路人最需要的就是電話，字要大到站在一公尺外也看得清楚。",
        "<b>寫走失的「區」和時間</b>：例如「大安區和平東路二段，11/5 晚上」。不用寫自家門牌。",
        "<b>寫一兩個好認的特徵</b>：項圈顏色、斷尾、耳朵缺角、走路微跛。不要寫一大段。",
        "<b>寫「看到請勿追趕」</b>：受驚的毛孩會越跑越遠。請路人拍照、記下時間地點再聯絡你。",
        "<b>放 QR Code</b>：手機掃一下就能回報目擊位置，比打電話更容易讓路人出手。"]],
      ["汪喵回家幫你自動做", [
        "登記走失大約 2 分鐘，不用註冊，完成後就有現成的協尋海報和 QR Code。",
        "路人掃 QR Code 回報的目擊，會直接通知你，並畫在案件頁的地圖時間軸上。",
        "海報可以直接存到相簿、傳到 LINE 群組，也有 A4 版可以去超商列印。"]]] },

  { id: "lost-post", sp: "all", ic: "📣", t: "走失協尋文怎麼寫？FB 社團、LINE 群組協尋貼文範本", s: "協尋文寫對了，才會有人願意分享。重點是讓看的人 5 秒內知道：哪裡、什麼時候、長什麼樣子、怎麼聯絡。",
    kw: "協尋文、走失協尋貼文、FB 走失社團、尋狗貼文範本、寵物協尋社團", faq: [
      ["要貼到哪些社團？", "先貼走失地點那個「區」或「里」的社團和社區 LINE 群，再貼縣市的走失協尋社團。只貼全台大社團，附近的人反而看不到。"],
      ["要不要放電話？", "社團貼文可以放，但詐騙也會看到。比較安全的做法是放汪喵回家的案件連結，路人可以直接在案件頁回報或傳訊息給你。"]],
    sec: [
      ["協尋文範本", [
        "【尋狗／尋貓】名字＋品種（例如：柴犬「小麥」）",
        "走失時間地點：11/5 晚上 8 點，臺北市大安區和平東路二段附近",
        "特徵：紅色項圈、左耳有缺角、很親人但會怕機車聲",
        "看到請勿追趕，請拍照記下時間地點，回報到協尋頁：（貼上汪喵回家的案件連結）",
        "照片放 2～4 張：全身、臉部、有特徵的部位"]],
      ["讓更多人分享的小技巧", [
        "<b>標題第一行就寫地區</b>，例如「大安區走失柴犬」，滑過去的人才會停下來。",
        "<b>每 1～2 天更新一次</b>：在原貼文留言補新的目擊、新照片，貼文會再浮上來。",
        "<b>找回來一定要回報</b>：在貼文和案件頁都標示「已找回」，謝謝大家，也讓大家不用再找。"]]] },

  { id: "pet-friends", sp: "all", ic: "🐾", t: "狗狗怎麼交朋友？找遛狗夥伴、狗友、貓友的方法", s: "想幫毛孩找玩伴、一起散步的狗友？這篇整理怎麼找、第一次見面怎麼做比較安全。",
    kw: "狗狗交朋友、遛狗夥伴、找狗友、狗友、貓友、寵物交友、毛孩交朋友、狗狗社交", faq: [
      ["狗狗需要交朋友嗎？", "大部分狗狗喜歡和合得來的同伴玩，適度的社交能消耗精力、減少吠叫和拆家。但每隻狗個性不同，怕生、年紀大的狗不用勉強，找一兩個固定玩伴就很好。"],
      ["去哪裡找附近的狗友？", "附近的公園、河濱、寵物友善咖啡廳是最常遇到狗友的地方。也可以用汪喵回家的「毛孩交朋友」，放上毛孩名片、看附近有哪些毛孩，或報名大家揪的散步團。"],
      ["第一次見面要注意什麼？", "約在公開、空間大的地方，雙方都繫好牽繩，讓狗狗先在旁邊並排走一段，再慢慢靠近互聞。看到夾尾巴、低吼、身體僵硬就先分開，下次再試。"]],
    sec: [
      ["先了解自己的毛孩", [
        "<b>體型和精力差不多最好玩</b>：小型犬和大型犬一起玩容易受傷，活潑的狗和慢熟的狗也可能玩不起來。",
        "<b>疫苗要打齊</b>：狂犬病、八合一等疫苗按時施打，驅蟲也要做，再去和其他毛孩接觸。",
        "<b>貓咪通常不需要出門交朋友</b>：大部分貓喜歡待在熟悉的環境，貓友多半是飼主之間交流，不一定要讓貓見面。"]],
      ["用汪喵回家找玩伴", [
        "<b>放上毛孩名片</b>：照片、品種、個性和所在的「區」，不公開住址和聯絡方式。",
        "<b>看到喜歡的毛孩按愛心</b>：飼主會知道誰喜歡牠，可以加好友、傳訊息打招呼。",
        "<b>報名或發起揪團</b>：選公園和時間，附近的毛孩家長都能報名，在活動頁一起討論幾點到、帶什麼。",
        "<a href=\"https://wangmiaotw.com/#/pals\">打開毛孩交朋友</a>，完全免費。"]],
      ["安全守則", [
        "只約公園、寵物餐廳這類公開地點，第一次見面不要約在家裡。",
        "禁止買賣、配種、送養收費，遇到騷擾或可疑的人可以檢舉、封鎖。",
        "牽繩、水和撿便袋一定要帶，狗狗玩累了要讓牠休息。"]]] },

  { id: "prevent-lost", sp: "all", ic: "🎆", t: "跨年煙火、颱風、搬家最容易走失：預防毛孩走失的 8 件事", s: "很多毛孩是在煙火、打雷、搬家、出門旅行這幾種時候走失的。事先做好這幾件事，最能避免。",
    kw: "狗怕煙火、跨年 狗走失、貓 搬家 走失、預防寵物走失、狗 鞭炮 逃跑", faq: [
      ["跨年、過年煙火時要怎麼保護狗狗？", "前一天就讓牠待在室內，關好門窗、拉上窗簾，開電視或音樂蓋過聲音。不要在煙火時段帶出門散步，項圈和牽繩要扣緊。"],
      ["搬家時貓咪怎麼不會跑掉？", "搬家當天把貓關在一間清空的房間或外出籠裡，門上貼「請勿開門」。到新家先關在一個房間幾天，熟悉了再慢慢開放。"]],
    sec: [
      ["平常就做好", [
        "<b>做寵物登記、植入晶片，電話要是最新的。</b>",
        "<b>項圈掛名牌</b>，寫上電話。",
        "<b>拍幾張清楚的照片</b>：全身、正臉、特徵部位。走失時馬上就能用。",
        "<b>門窗、陽台加裝防護</b>：貓咪最常從紗窗和陽台跑出去。"]],
      ["最容易走失的時候", [
        "<b>煙火、鞭炮、打雷</b>：跨年、過年、颱風天前就讓牠待在室內，關好門窗。",
        "<b>搬家、裝潢</b>：工人進出、門常開著，把毛孩關在一間房間或寄放。",
        "<b>出門旅行、寄宿</b>：交給保母或寄宿前，確認對方知道牠怕什麼、牽繩怎麼扣。",
        "<b>剛領養回家</b>：新環境還不熟，前幾週出門一定要牽好，貓咪先不要讓牠出門。"]],
      ["萬一真的走失", [
        "照<a href=\"https://wangmiaotw.com/g/dog-lost\">狗走失怎麼辦</a>或<a href=\"https://wangmiaotw.com/g/cat-lost\">貓走失怎麼找</a>的步驟做，第一時間在汪喵回家免費登記協尋。"]]] },
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

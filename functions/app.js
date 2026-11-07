// 短網址 wangmiaotw.com/app → App Store（給 IG、海報、口頭分享用，好記好打）
// Android 還沒上架：先帶到網站首頁
const STORE = "https://apps.apple.com/tw/app/id6827632980";
export const onRequest = ({ request }) => {
  const ua = request.headers.get("User-Agent") || "";
  const to = /Android/i.test(ua) ? "https://wangmiaotw.com/" : STORE;
  return new Response(null, { status: 302, headers: { Location: to, "Cache-Control": "no-store" } });
};

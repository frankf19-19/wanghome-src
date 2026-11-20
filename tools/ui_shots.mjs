// 介面截圖：用 Playwright 開正式站，手機與桌機各截一輪（給改版前後比對）
import { chromium, devices } from "playwright";
const BASE = process.env.BASE || "https://wangmiaotw.com/";
const routes = (process.env.ROUTES || "#/,#/case/97aee9ea-194d-402e-8bcb-24c2cc3cbeb9,#/new,#/found/new,#/seen,#/photo,#/adopt,#/pals,#/learn,#/resources,#/intake,#/injured,#/about").split(",");
const extra = (process.env.PATHS || "g/dog-lost,l/%E8%87%BA%E5%8D%97%E5%B8%82,p/97aee9ea-194d-402e-8bcb-24c2cc3cbeb9").split(",").filter(Boolean);
const tag = process.env.TAG || "before";
const browser = await chromium.launch();
for (const [name, opt] of [["m", { ...devices["iPhone 13"] }], ["d", { viewport: { width: 1280, height: 860 } }]]) {
  const ctx = await browser.newContext({ ...opt, locale: "zh-TW", colorScheme: "light" });
  const page = await ctx.newPage();
  let i = 0;
  for (const r of routes) {
    await page.goto(BASE + r, { waitUntil: "networkidle", timeout: 45000 }).catch(() => {});
    await page.waitForTimeout(2500);
    if (r === "#/") { await page.click('[aria-label="格狀"]').catch(() => {}); await page.waitForTimeout(1500); }
    await page.screenshot({ path: `shots/${tag}-${name}-${String(i++).padStart(2, "0")}-${r.replace(/[#\/]+/g, "_").slice(0, 30) || "home"}.jpg`, fullPage: name === "m", type: "jpeg", quality: 70 });
  }
  for (const p of extra) {
    await page.goto(BASE + p, { waitUntil: "networkidle", timeout: 45000 }).catch(() => {});
    await page.waitForTimeout(1500);
    await page.screenshot({ path: `shots/${tag}-${name}-${String(i++).padStart(2, "0")}-ssr-${p.split("/")[0]}.jpg`, fullPage: name === "m", type: "jpeg", quality: 70 });
  }
  await ctx.close();
}
await browser.close();

#!/usr/bin/env node
// 把 index.html 裡「毛孩小學堂」的文章（const LEARN=[...]）抽成 lib/learn.js，
// 給搜尋引擎用的靜態頁（/g/…）共用同一份內容，不用維護兩份。
// 用法：node scripts/gen_learn.js   （build.sh 會自動跑）
const fs = require("fs"), path = require("path"), vm = require("vm");
const root = path.join(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const m = html.match(/\nconst LEARN=(\[[\s\S]*?\n\]);\n/);
if (!m) { console.error("gen_learn: 找不到 const LEARN=[...]"); process.exit(1); }
const LEARN = vm.runInNewContext("(" + m[1] + ")", {});
if (!Array.isArray(LEARN) || LEARN.length < 5) { console.error("gen_learn: LEARN 內容不對"); process.exit(1); }
for (const a of LEARN) for (const k of ["id", "sp", "t", "s", "b"]) if (!(k in a)) { console.error("gen_learn: 文章缺欄位 " + k, a.id); process.exit(1); }
const out = path.join(root, "lib", "learn.js");
const json = "// 自動產生：node scripts/gen_learn.js（來源 index.html 的 const LEARN），請勿手改\nexport default " + JSON.stringify(LEARN) + ";\n";
if (fs.existsSync(out) && fs.readFileSync(out, "utf8") === json) { console.log("learn.js 沒變（" + LEARN.length + " 篇）"); process.exit(0); }
fs.writeFileSync(out, json);
console.log("learn.js 已更新：" + LEARN.length + " 篇");

#!/usr/bin/env bash
# Cloudflare Pages 建置：只把「網頁需要的檔案」放進 dist/，並壓縮 index.html（加快載入、程式碼不易直接閱讀）。
# 程式說明、資料庫設定、排程程式（scripts/、supabase/、SETUP.md）不會出現在網站上。
# 壓縮失敗時自動改用原始檔，網站照常更新。
set -euo pipefail
# 安全檢查：網頁裡的程式有語法錯誤就停止部署（Cloudflare 會繼續用上一個正常的版本）
check(){ node -e '
const vm=require("vm");const f=process.argv[1];const s=require("fs").readFileSync(f,"utf8");const re=/<script>([\s\S]*?)<\/script>/g;let m,i=0,bad=0;
while((m=re.exec(s))){i++;try{new vm.Script(m[1],{filename:f+"#"+i})}catch(e){bad++;console.error(f+" script #"+i+" 語法錯誤："+e.message)}}
if(!i){console.error(f+" 找不到程式");process.exit(1)}if(bad)process.exit(1);console.log(f+" syntax ok: "+i+" scripts");' "$1"; }
check index.html
node scripts/gen_learn.js   # 毛孩小學堂文章 → lib/learn.js（給 /g/ 靜態頁用）
rm -rf dist && mkdir -p dist
cp sw.js manifest.webmanifest _headers dist/
[ -f robots.txt ] && cp robots.txt dist/
[ -f sitemap.xml ] && cp sitemap.xml dist/ || true   # 改由 functions/sitemap.xml.js 即時產生
[ -f 404.html ] && cp 404.html dist/
cp google*.html BingSiteAuth.xml 73080c78bdeeab41a5d6fcb7fa0d1bc7.txt dist/ 2>/dev/null || true   # 搜尋引擎驗證檔（Search Console / Bing）與 IndexNow 金鑰檔
cp ./*.png ./*.svg ./shot-*.jpg dist/
mkdir -p dist/vendor && cp vendor/*.js vendor/*.css dist/vendor/
# 照片找毛孩：AI 模型（DINOv2-small 量化版）和執行環境（onnxruntime-web），使用者第一次用到才下載
mkdir -p dist/vendor/ort dist/ai && cp vendor/ort/* dist/vendor/ort/ && cp ai/dinov2s-q8.onnx ai/yolox_nano.onnx dist/ai/
# iOS 通用連結（LINE 登入跳回 App）與它的備用頁
mkdir -p dist/.well-known dist/line-auth && cp .well-known/apple-app-site-association dist/.well-known/ && cp line-auth/index.html dist/line-auth/
if npx --yes html-minifier-terser@7.2.0 --config-file minify.config.json -o dist/index.html index.html 2>/tmp/minify.log \
   && [ -s dist/index.html ] && grep -Eq 'BUILD="v[0-9.]+"' dist/index.html && grep -q '</html>' dist/index.html; then
  echo "minified index.html: $(wc -c < index.html) -> $(wc -c < dist/index.html) bytes"
else
  echo "minify failed, using original:"; cat /tmp/minify.log || true
  cp index.html dist/index.html
fi
check dist/index.html
# 版本檔：網站用來檢查有沒有新版（很小，不用整頁重新下載）
V=$(grep -oE "const BUILD = 'v[0-9.]+'" index.html | grep -oE "v[0-9.]+")
[ -n "$V" ] && printf '{"v":"%s"}\n' "$V" > dist/version.json
# 每次發版換 service worker 的快取名稱，舊快取（圖示、manifest）才會更新
# （不用 sed -i：Mac 和 Linux 的寫法不同，App 在 Mac 上打包）
if [ -n "$V" ]; then sed "s/const CACHE = 'wanghome-[^']*'/const CACHE = 'wanghome-$V'/" dist/sw.js > dist/sw.js.tmp && mv dist/sw.js.tmp dist/sw.js; fi
# App 線上更新包：App 啟動時比對 /app-live/manifest.json，有新版就下載這些檔案，下次開 App 改用新畫面（不用每次送審）
# minNative：新畫面需要的最低 App 原生版本（加了新的原生外掛才要調高 app/live-min-native），舊 App 會繼續用自己內建的畫面
bash scripts/make_app_www.sh dist dist/app-live >/dev/null
node -e '
const fs=require("fs"),path=require("path"),crypto=require("crypto");const dir="dist/app-live";const files=[];
(function walk(d){for(const n of fs.readdirSync(d)){const f=path.join(d,n);if(fs.statSync(f).isDirectory())walk(f);else files.push(path.relative(dir,f))}})(dir);
fs.renameSync(path.join(dir,"index.html"),path.join(dir,"index.page.txt"));   // Cloudflare 會把 .html 轉址，改名避開
const list=files.sort().map(p=>{const u=p==="index.html"?"index.page.txt":p;const b=fs.readFileSync(path.join(dir,u));return {p,u,s:b.length,h:crypto.createHash("sha256").update(b).digest("hex").slice(0,16)}});
let min=0;try{min=parseInt(fs.readFileSync("app/live-min-native","utf8"),10)||0}catch(_){}
fs.writeFileSync(path.join(dir,"manifest.json"),JSON.stringify({build:process.argv[1],minNative:min,files:list}));
console.log("app-live:",list.length,"files,",list.reduce((a,b)=>a+b.s,0),"bytes, minNative",min);' "$V"
echo "built: $(find dist -type f | wc -l) files"

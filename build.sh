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
rm -rf dist && mkdir -p dist
cp sw.js manifest.webmanifest _headers dist/
[ -f robots.txt ] && cp robots.txt dist/
[ -f sitemap.xml ] && cp sitemap.xml dist/
[ -f 404.html ] && cp 404.html dist/
cp ./*.png ./*.svg ./shot-*.jpg dist/
mkdir -p dist/vendor && cp vendor/*.js vendor/*.css dist/vendor/
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
echo "built: $(find dist -type f | wc -l) files"

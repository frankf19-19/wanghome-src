#!/usr/bin/env bash
# Cloudflare Pages 建置：只把「網頁需要的檔案」放進 dist/，並壓縮 index.html（加快載入、程式碼不易直接閱讀）。
# 程式說明、資料庫設定、排程程式（scripts/、supabase/、SETUP.md）不會出現在網站上。
# 壓縮失敗時自動改用原始檔，網站照常更新。
set -euo pipefail
rm -rf dist && mkdir -p dist
cp sw.js manifest.webmanifest _headers dist/
[ -f robots.txt ] && cp robots.txt dist/
[ -f sitemap.xml ] && cp sitemap.xml dist/
[ -f 404.html ] && cp 404.html dist/
cp ./*.png ./*.svg dist/
for d in s f; do mkdir -p "dist/$d"; cp -r "$d"/. "dist/$d"/ 2>/dev/null || true; done
if npx --yes html-minifier-terser@7.2.0 --config-file minify.config.json -o dist/index.html index.html 2>/tmp/minify.log \
   && [ -s dist/index.html ] && grep -Eq 'BUILD="v[0-9.]+"' dist/index.html && grep -q '</html>' dist/index.html; then
  echo "minified index.html: $(wc -c < index.html) -> $(wc -c < dist/index.html) bytes"
else
  echo "minify failed, using original:"; cat /tmp/minify.log || true
  cp index.html dist/index.html
fi
echo "built: $(find dist -type f | wc -l) files"

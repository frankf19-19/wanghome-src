#!/usr/bin/env bash
# Cloudflare Pages 建置：只把「網頁需要的檔案」放進 dist/，
# 程式說明、資料庫設定、排程程式（scripts/、supabase/、SETUP.md）不會出現在網站上。
set -euo pipefail
rm -rf dist && mkdir -p dist
cp index.html sw.js manifest.webmanifest _headers dist/
cp ./*.png ./*.svg dist/
for d in s f; do mkdir -p "dist/$d"; cp -r "$d"/. "dist/$d"/ 2>/dev/null || true; done
echo "built: $(find dist -type f | wc -l) files"

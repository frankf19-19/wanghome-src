#!/usr/bin/env bash
# 從網站建置結果（dist/）做出 App 用的網頁資料夾：
#   bash scripts/make_app_www.sh dist app/www          ← 打包進 App（prepare-web.sh）
#   bash scripts/make_app_www.sh dist dist/app-live     ← App 線上更新用（build.sh），另外產生 manifest.json
# App 裡不需要 Service Worker、Cloudflare 標頭、404 頁、搜尋引擎驗證檔；改用網頁內的 CSP。
set -euo pipefail
SRC="$1"; DST="$2"
rm -rf "$DST" && mkdir -p "$DST"
( cd "$SRC" && tar cf - --exclude=./app-live . ) | ( cd "$DST" && tar xf - )
rm -f "$DST"/sw.js "$DST"/_headers "$DST"/404.html "$DST"/robots.txt "$DST"/sitemap.xml "$DST"/mail-logo*.png "$DST"/og.png "$DST"/shot-*.jpg
rm -f "$DST"/google*.html "$DST"/BingSiteAuth.xml "$DST"/[0-9a-f]*[0-9a-f].txt
rm -rf "$DST"/.well-known "$DST"/line-auth
# AI 模型和 wasm 很大（共約 35MB），不放進 App；App 用到時直接從 wangmiaotw.com 下載
rm -rf "$DST"/ai; rm -f "$DST"/vendor/ort/*.wasm
CSP="default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' data: https://fonts.gstatic.com; img-src 'self' data: blob: https:; connect-src 'self' https://wangmiaotw.com https://nopyhfpaykkiieudvoko.supabase.co wss://nopyhfpaykkiieudvoko.supabase.co https://data.moa.gov.tw https://nominatim.openstreetmap.org; media-src 'self' blob: https://nopyhfpaykkiieudvoko.supabase.co; frame-src 'none'; object-src 'none'; base-uri 'self'"
node -e '
const fs=require("fs"),f=process.argv[2]+"/index.html";let s=fs.readFileSync(f,"utf8");
const tag=`<meta http-equiv="Content-Security-Policy" content="${process.argv[1]}">`;
if(!/<head[^>]*>/i.test(s))throw new Error("no <head>");
s=s.replace(/<head([^>]*)>/i,m=>m+tag);
s=s.replace(/<link[^>]+rel="?manifest"?[^>]*>/i,"");
fs.writeFileSync(f,s);console.log(process.argv[2]+" ready:",s.length,"bytes");' "$CSP" "$DST"
# 檔案清單：App 第一次線上更新前，會照這份清單把內建畫面複製一份當作「退回用」的備份
( cd "$DST" && find . -type f ! -name app-files.json | sed 's|^\./||' | sort | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s.trim().split("\n"))))' > app-files.json )

#!/usr/bin/env bash
# 把網站打包進 App：先用網站的 build.sh 產生 dist/，再複製到 app/www/。
# App 裡不需要 Service Worker、Cloudflare 標頭和 404 頁；改用網頁內的 CSP。
set -euo pipefail
cd "$(dirname "$0")/.."
bash build.sh
rm -rf app/www && mkdir -p app/www
cp -R dist/. app/www/
rm -f app/www/sw.js app/www/_headers app/www/404.html app/www/robots.txt app/www/sitemap.xml app/www/mail-logo*.png app/www/og.png
CSP="default-src 'self'; script-src 'self' 'unsafe-inline' https://unpkg.com https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://unpkg.com; font-src 'self' data: https://fonts.gstatic.com; img-src 'self' data: blob: https:; connect-src 'self' https://wangmiaotw.com https://nopyhfpaykkiieudvoko.supabase.co wss://nopyhfpaykkiieudvoko.supabase.co https://data.moa.gov.tw https://nominatim.openstreetmap.org; media-src 'self' blob:; frame-src 'none'; object-src 'none'; base-uri 'self'"
node -e '
const fs=require("fs"),f="app/www/index.html";let s=fs.readFileSync(f,"utf8");
const tag=`<meta http-equiv="Content-Security-Policy" content="${process.argv[1]}">`;
if(!/<head[^>]*>/i.test(s))throw new Error("no <head>");
s=s.replace(/<head([^>]*)>/i,m=>m+tag);
s=s.replace(/<link[^>]+rel="?manifest"?[^>]*>/i,"");
fs.writeFileSync(f,s);console.log("app/www ready:",s.length,"bytes");' "$CSP"

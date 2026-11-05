#!/usr/bin/env bash
# 把網站打包進 App：先用網站的 build.sh 產生 dist/，再轉成 App 用的 app/www/。
set -euo pipefail
cd "$(dirname "$0")/.."
bash build.sh
bash scripts/make_app_www.sh dist app/www

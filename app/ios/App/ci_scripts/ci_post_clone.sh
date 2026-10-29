#!/bin/sh
# 汪喵回家 — Xcode Cloud：下載程式碼後、編譯前執行
# 1. 裝 Node.js  2. 把網站打包進 App 並同步 Capacitor 外掛（Swift 套件指向 node_modules）
# 3. 版本號：MARKETING_VERSION 用 app/package.json 的 version；
#    建置號用 Xcode Cloud 的 CI_BUILD_NUMBER + 1000（GitHub 時期上傳過的建置號都小於 1000，不會撞號）
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
command -v node >/dev/null 2>&1 || brew install node
node -v
cd app
npm ci --no-audit --no-fund
bash prepare-web.sh
npx cap sync ios
V=$(node -p "require('./package.json').version")
B=$(( ${CI_BUILD_NUMBER:-0} + 1000 ))
P=ios/App/App.xcodeproj/project.pbxproj
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $V;/; s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $B;/" "$P"
echo "版本 $V（建置 $B）準備完成"

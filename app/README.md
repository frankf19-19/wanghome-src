# 汪喵回家 App（iOS／Android）

App 是把網站（`index.html` 經 `build.sh` 產生的 `dist/`）打包進 Capacitor 原生殼。
網站改了，App 只要重新編譯就會帶上新版；網頁版完全不受 App 影響。

## 原生功能
- 相機拍照、相簿選照片（協尋、通報、健康紀錄）
- 定位（標出走失／目擊地點、附近案件）
- 系統分享（海報、分享連結、日曆檔）
- 手機通知提醒：回診／疫苗／驅蟲到期前一天早上 9 點、每天用藥時間（健康手冊 →「開啟手機通知」）
- Android 返回鍵、從分享連結開啟 App

## 編譯（GitHub Actions，不需要自己的電腦）
GitHub → Actions：
- **App Android** → Run workflow：產生測試用 `.apk`（可直接裝在 Android 手機）。設定好簽章密鑰後，同時產生可上傳 Google Play 的 `.aab`。
- **App iOS** → Run workflow：沒有 Apple 金鑰時只做編譯檢查；設定好金鑰後自動上傳到 TestFlight。
- 推送 `app-v1.0.1` 這種標籤，兩個都會自動執行。
- 要改版本號：改 `app/package.json` 的 `version`（例如 1.0.1）。建置編號會自動遞增。

## 需要設定的 Secrets（GitHub → Settings → Secrets and variables → Actions）
Android（Google Play 上傳金鑰）：
- `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`

iOS（App Store Connect → 使用者與存取 → 整合 → App Store Connect API，建立「App 管理」權限的金鑰）：
- `ASC_API_KEY_P8`：下載的 .p8 檔全部內容
- `ASC_KEY_ID`、`ASC_ISSUER_ID`
- `APPLE_TEAM_ID`：Apple Developer 會員資料裡的 Team ID（10 碼）

## 資料夾
- `prepare-web.sh`：建置網站並複製到 `www/`，移除 Service Worker，加入 App 用的 CSP
- `capacitor.config.json`：App ID `com.wangmiaotw.app`、名稱、啟動畫面
- `assets/`：圖示與啟動畫面原圖（改圖後執行 `npx capacitor-assets generate`）
- `ios/`、`android/`：原生專案

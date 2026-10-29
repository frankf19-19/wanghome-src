# 汪喵回家 WangHome — 安裝說明（v1.7.0）

## ✅ 目前已部署
- 網站：https://wangmiaotw.com/
- GitHub：https://github.com/frankf19-19/wanghome
- Supabase 專案：wanghome（東京，ref `nopyhfpaykkiieudvoko`）
  - 資料庫結構 schema.sql + migration_v1.1.sql + migration_v1.2.sql + migration_v1.3.sql + migration_v1.4.sql + migration_v1.5.sql + migration_v1.6.sql 已執行、publishable key 已填入 index.html
- GitHub Actions：SUPABASE_URL / SITE_URL / SITE_NAME 已直接寫在 workflow
  - 只需要 Secret：`SUPABASE_SERVICE_KEY`（Supabase → Settings → API Keys → Secret key）
  - 選填 Secret：`GMAIL_USER`、`GMAIL_APP_PASSWORD`（寄通知）、`MOA_API_URL`

以下為從零安裝的完整步驟（重建時參考）。

---

全部免費：GitHub Pages（前端）＋ Supabase（資料庫/照片）＋ GitHub Actions（每日比對、通知）。
整個流程約 30 分鐘，不需要寫任何程式。

---

## 檔案結構

```
wanghome/
├── index.html                 ← 整個網站（只需改最上面 CONFIG）
├── supabase/schema.sql        ← 資料庫結構，在 Supabase 執行一次
├── scripts/daily.py           ← 每日比對收容所 + 寄通知
├── .github/workflows/daily.yml← 排程
└── SETUP.md
```

---

## 第 1 步：建立 Supabase 專案（10 分鐘）

1. 到 https://supabase.com 註冊，New project
   - Name：wanghome
   - Database password：隨便設一組，記下來（之後用不到）
   - Region：**Northeast Asia (Tokyo)** 離台灣最近
2. 建好後，左側 **SQL Editor** → New query → 把 `supabase/schema.sql` 全部貼上 → **Run**
   - 最後一行會顯示 `WangHome schema v1.0.0 installed`
   - 再開一個 New query，貼上 `supabase/migration_v1.1.sql` → **Run**（拾獲通報、長度限制、防灌水）
   - 再跑 `supabase/migration_v1.2.sql`（收容所比對結果寫回）
   - 再跑 `supabase/migration_v1.3.sql`（支援貓）
   - 再跑 `supabase/migration_v1.4.sql`（會員系統）
   - 再跑 `supabase/migration_v1.5.sql`（檢舉與管理後台）
   - 再跑 `supabase/migration_v1.6.sql`（毛孩健康紀錄、私密照片空間）
   - 再依序跑 `migration_v1.7.sql`（日曆）、`v1.8`（受傷通報）、`v1.9`（用藥）、`v1.10`（照片網址檢查、通知修正）
3. 左側 **Project Settings → API**，記下兩個值：
   - **Project URL**（像 `https://abcdefgh.supabase.co`）
   - **Publishable key**（以 `sb_publishable_` 開頭；舊版 anon key 也可）
   - 同頁下面的 **Secret key**（`sb_secret_` 開頭，或舊版 service_role）等一下 GitHub 要用，**絕對不能貼進 index.html**
4. 左側 **Storage** 確認有一個 `photos` bucket（schema.sql 會自動建）。如果沒有：New bucket → 名稱 `photos` → Public bucket 打勾。

## 第 2 步：設定前端（2 分鐘）

打開 `index.html`，最上方找到：

```js
const CONFIG = {
  SITE_NAME: '汪喵回家',
  SUPABASE_URL: '',          // ← 貼 Project URL
  SUPABASE_ANON_KEY: '',     // ← 貼 anon public key
  ECPAY_URL: '',             // ← 綠界實況主收款網址（可晚點填）
  CONTACT_EMAIL: '',         // ← 站長信箱
  ...
```

存檔。SITE_NAME 可以改成你喜歡的名字。

## 第 3 步：上傳到 GitHub Pages（5 分鐘）

1. GitHub 建一個新 repo，例如 `wanghome`（Public）
2. 把整個資料夾的檔案上傳（包含 `.github` 資料夾）
3. repo → **Settings → Pages** → Source 選 `Deploy from a branch` → Branch `main` / `(root)` → Save
4. 幾分鐘後網址是 `https://你的帳號.github.io/wanghome/`
5. 打開網站，如果看到首頁而不是「還差一步」畫面，就代表前端 OK

## 第 4 步：設定 GitHub Actions（收容所比對 + 通知）（5 分鐘）

repo → **Settings → Secrets and variables → Actions → New repository secret**，逐一新增：

| Name | Value |
|---|---|
| `SUPABASE_URL` | 第 1 步的 Project URL |
| `SUPABASE_SERVICE_KEY` | 第 1 步的 **service_role** key |
| `SITE_URL` | `https://你的帳號.github.io/wanghome/` |
| `SITE_NAME` | 汪喵回家（或你改的名字） |
| `GMAIL_USER` | 用來寄通知的 Gmail 帳號 |
| `GMAIL_APP_PASSWORD` | Gmail 應用程式密碼（見下方） |

**Gmail 應用程式密碼怎麼拿**：Google 帳號 → 安全性 → 開啟兩步驟驗證 → 搜尋「應用程式密碼」→ 建立一組（16 碼）。建議專門申請一個新的 Gmail 當寄件信箱。

設好後 repo → **Actions** → 左側 `WangHome daily match & notify` → **Run workflow** 手動跑一次。
綠色打勾就 OK。點進去看 log 會顯示「農業部資料筆數：xxxx」。

> 如果 log 顯示抓取農業部資料失敗，請到 https://data.gov.tw/dataset/85903 找「資料資源下載網址」(JSON)，
> 新增一個 Secret `MOA_API_URL` 貼上該網址即可。

排程：每天台灣時間 03:17 做收容所比對；每 2 小時寄一次目擊通知。

## 第 5 步：綠界贊助（可選）

1. https://www.ecpay.com.tw 申請個人會員（身分證驗證，免費）
2. 廠商後台 → 收款工具 → **實況主收款** → 贊助連結設定 → 啟用
   - 最低贊助金額建議設 50
   - 打開「讓贊助者填暱稱與留言」
3. 把產生的網址（像 `https://p.ecpay.com.tw/XXXXXXX`）貼到 `index.html` 的 `ECPAY_URL`
4. 收到贊助後，到 Supabase → **Table Editor → sponsors** → Insert row，填 nickname、message、amount、sponsored_on，感謝牆就會顯示
   - `show_amount` 預設 false（不公開金額），要公開就改 true
5. 記得每年至少提領一次，超過 365 天未提領綠界會收帳管費

---

## 日常管理

- **看所有案件、目擊、刪除惡作劇**：Supabase → Table Editor
- **飼主遺失管理金鑰**：Table Editor → cases → 找到那筆 → 你無法看到原金鑰（只存雜湊），但可以直接幫他改 status，或請他重新登記
- **統計**：Table Editor 右上角可以看筆數；`found_stats` view 是找回方式統計
- **保活**：Actions 每天會查一次資料庫，免費專案不會因閒置被暫停

## 之後要改的東西

- `index.html` 的 CONFIG 區塊（名稱、連結）
- `scripts/daily.py` 裡的 `score()` 可以調整比對門檻（目前 ≥45 分才算疑似）

## 安全提醒

- `anon` key 可以公開（它只能做前端允許的事）
- `service_role` key 等於管理員密碼，**只放 GitHub Secrets**
- 所有飼主私密資料（Email、回報者聯絡方式、管理金鑰）都不會從公開 API 流出


## 收容所比對為什麼在瀏覽器跑？
農業部開放資料（data.moa.gov.tw）只接受台灣 IP，GitHub Actions（美國）和 Supabase（東京）都連不上。
所以改成：任何人打開案件頁時，由他的瀏覽器抓「該縣市的收容犬」（約 1MB），比對後把新結果寫回資料庫。
飼主管理頁打開時也會重新比對。若之後有台灣的代理伺服器，設定 GitHub Secret `MOA_API_URL` 即可恢復每日伺服器端比對。


## 會員登入設定（v1.4）
Supabase → Authentication → URL Configuration：
- Site URL：`https://wangmiaotw.com/`
- Redirect URLs：加入 `https://wangmiaotw.com/**`

登入採用 Email 魔法連結（PKCE），不需要密碼。

### 正式使用前務必設定自己的寄信服務（SMTP）
Supabase 內建寄信每小時只能寄很少封，只適合測試。建議用 Resend（免費每月 3,000 封）：
1. 註冊 https://resend.com ，建立 API Key
2. Supabase → Authentication → Emails → SMTP Settings → Enable custom SMTP
   - Host：`smtp.resend.com`，Port：`465`，Username：`resend`，Password：你的 Resend API Key
   - Sender email：沒有自己的網域時用 `onboarding@resend.dev`（只能寄給自己測試），正式使用需在 Resend 驗證網域
3. Authentication → Rate Limits 可把每小時寄信上限調高

### Google 登入（選用）
1. Google Cloud Console → APIs & Services → Credentials → 建立 OAuth Client ID（Web application）
   - Authorized redirect URI：`https://nopyhfpaykkiieudvoko.supabase.co/auth/v1/callback`
2. Supabase → Authentication → Sign In / Providers → Google → 貼上 Client ID 與 Client Secret → 啟用
3. `index.html` 的 CONFIG 把 `GOOGLE_LOGIN` 改成 `true`

### 會員通知
附近走失、追蹤案件的 Email 通知由 GitHub Actions 每 2 小時寄出，需要設定 Secrets：`GMAIL_USER`、`GMAIL_APP_PASSWORD`。


## 管理後台與檢舉（v1.5）
- 設定管理員（在 Supabase SQL Editor 執行，email 換成你登入用的信箱）：
  `update public.profiles set is_admin = true where id = (select id from auth.users where email = '你的信箱');`
- 管理員登入後，「👤 我的」頁會出現「🛡 管理後台」，可隱藏案件、退回目擊、標記檢舉已處理。
- 有新檢舉時，daily 排程會寄信到 `ADMIN_EMAIL`（未設定則寄到 `GMAIL_USER`）。

## 分享預覽頁（v3.14 起改為即時產生）
`/s/<案件id>`、`/f/<拾獲id>` 由 Cloudflare Pages Functions（`functions/s/[id].js`、`functions/f/[id].js`，共用 `lib/share.js`）
在有人打開連結時即時查公開資料產生，貼到 LINE / Facebook 會顯示照片、名字、地點。
- 案件刪除或被隱藏後，分享頁立刻變成 404，不會留在 git 歷史。
- 不再需要 `share.yml` 排程，也不會有機器人 commit。
- 只讀公開資料（publishable key），不需要秘密金鑰。

## 毛孩健康紀錄（v1.7）
- 會員在「我的 → 我的毛孩」點進寵物，可記錄看診、疫苗、驅蟲、用藥、手術、體重、美容；可設定下次到期日。
- 收據／病歷照片存在私密空間 `pet-private`（非公開，只有本人能讀，顯示用 1 小時有效的簽名網址）。
- 「給獸醫看」頁可列印或存成 PDF。
- 到期前 7 天會寄 Email 提醒（每天 03:17 的排程，需 Gmail 設定）。

## v1.8：日曆同步
1. Supabase SQL Editor 執行 `supabase/migration_v1.7.sql`（新增 profiles.calendar_token）。
2. Supabase → Edge Functions → 建立函式 `pet-calendar`，貼上 `supabase/functions/pet-calendar/index.ts`，
   並**關閉 Verify JWT**（日曆 App 無法帶登入資訊，改用私人 token 辨識）。
3. 會員在「我的」頁面按 Google／iPhone／Outlook 即可訂閱；每筆到期提醒也可單獨加到 Google 日曆或下載 .ics。

## 網域與寄信（2026-10 起）
- 網站：https://wangmiaotw.com（Cloudflare Pages，從 GitHub main 自動部署，建置指令 `bash build.sh`，輸出 `dist`）
- 舊網址 frankf19-19.github.io/wanghome 會自動轉到新網址（index.html 開頭的搬家程式）
- 客服信箱 service@wangmiaotw.com → Cloudflare Email Routing 轉寄到站長 Gmail
- 所有寄信（登入信、加入會員信、目擊通知、每日通知）都用 Resend，寄件人「汪喵回家 noreply@wangmiaotw.com」
  - Supabase → Authentication → Emails → SMTP：smtp.resend.com / 465 / resend / 密碼＝Resend 金鑰
  - Supabase Edge Functions Secrets：`RESEND_API_KEY`
  - GitHub Actions Secrets：`RESEND_API_KEY`
  - 中文信件範本：supabase/email-templates/

## 防濫用（v1.17 起）
- 飼主 Email 要先點「確認信箱」信才會收到任何通知（登入會員填自己帳號的信箱會自動確認）
- 每個人（依 Cloudflare 提供的 IP）有各自的送出上限：新案件每小時 10 件、拾獲通報每小時 20 筆、目擊 10 分鐘 20 筆、檢舉 10 分鐘 20 筆
- 每天的排程會清掉沒人用、超過 3 天的公開照片；手動執行可在 Actions 選 `cleanup-dry`（試跑不刪）或 `cleanup`

## 安全加強（v1.19 / 網站 v3.14）
- 執行 `supabase/migration_v1.19.sql`：IPv6 次數限制以 /64 計算、確認信冷卻不因換信箱重設、改信箱限次數、
  非飼主送來的收容所比對嚴格過濾、附近通知只寄確認過的案件、公開照片單檔 2MB 並限上傳次數、瀏覽數防灌水、Email 格式檢查。
- 重新部署 `notify-sighting`（v1.4）：確認信每案一天 3 封、全站每小時 30 封（和目擊通知分開計）、信件不含使用者填的文字。

## 免費額度保護（v1.21 / 網站 v3.15）
- GitHub repo 已改名為 `wanghome-src` 並設為私人；公開的 `wanghome` repo 只放舊網址轉址頁（帶舊網址的管理代碼到新網址）。
- **每日寄信預算**：Resend 免費版一天 100 封，登入信也走同一個帳號。網站通知一天最多 60 封（保留 40 封給登入信），
  會員通知（附近走失、追蹤、到期提醒）只用到第 40 封。預算由 `mail_budget_take()` 控制，排程與 notify-sighting 共用。
  網站變大後請升級 Resend 方案，或另外設定登入信專用的寄件服務。
- 附近走失通知改成每天凌晨寄一次彙整。
- `retention_cleanup()` 每天清理：通知紀錄 60 天、次數限制紀錄 2 天、結案 30 天以上的收容所比對；拾獲／目擊通報 60 天自動結案（結案後不公開通報者聯絡方式）。
- 照片清理每週日跑一次；上傳照片改為 1080px（海報寬度）。
- 排程同時只跑一個、最多 15 分鐘。
- Cloudflare Pages 免費版一個月 500 次部署：修改請集中推送。

## 每日比對／通知改由 Supabase 排程（v1.33，2026-10-29）
原本 GitHub Actions 的 `daily.yml` 排程改到 Supabase 執行，不再吃 GitHub Actions 每月 2,000 分鐘額度
（私人 repo 的 iOS 打包用 macOS，一分鐘算十分鐘，很容易用完，用完後通知就會停）。
1. Supabase → Edge Functions → 建立函式 `daily-run`，貼上 `supabase/functions/daily-run/index.ts`，**關閉 Verify JWT**。
   - 用的 Secrets 和 notify-sighting 相同（`RESEND_API_KEY`），不用另外設定；選填 `MOA_API_URL`、`ADMIN_EMAIL`。
2. Supabase → SQL Editor 執行 `supabase/migration_v1.33.sql`（開啟 pg_cron／pg_net、產生排程密碼、建立三個排程）。
3. 測試：SQL Editor 執行 `select public.daily_run_call('notify');`，幾秒後到 Edge Functions → daily-run → Logs 看結果。
- 排程：每天 03:17 `nightly`（比對＋通知＋到期提醒＋定期清理）、03:47 `cleanup`（清照片）、每 2 小時 `notify`。
- GitHub 的 `daily.yml` 只保留手動執行當備援；`scripts/daily.py` 暫時保留，邏輯和 daily-run 相同。

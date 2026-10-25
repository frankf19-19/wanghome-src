# 汪回家 WangHome — 安裝說明（v1.0.1）

## ✅ 目前已部署
- 網站：https://frankf19-19.github.io/wanghome/
- GitHub：https://github.com/frankf19-19/wanghome
- Supabase 專案：wanghome（東京，ref `nopyhfpaykkiieudvoko`）
  - 資料庫結構已執行、publishable key 已填入 index.html
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
3. 左側 **Project Settings → API**，記下兩個值：
   - **Project URL**（像 `https://abcdefgh.supabase.co`）
   - **Publishable key**（以 `sb_publishable_` 開頭；舊版 anon key 也可）
   - 同頁下面的 **Secret key**（`sb_secret_` 開頭，或舊版 service_role）等一下 GitHub 要用，**絕對不能貼進 index.html**
4. 左側 **Storage** 確認有一個 `photos` bucket（schema.sql 會自動建）。如果沒有：New bucket → 名稱 `photos` → Public bucket 打勾。

## 第 2 步：設定前端（2 分鐘）

打開 `index.html`，最上方找到：

```js
const CONFIG = {
  SITE_NAME: '汪回家',
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
| `SITE_NAME` | 汪回家（或你改的名字） |
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

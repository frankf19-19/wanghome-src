# 登入／加入會員信（Supabase Auth 範本）

Supabase → Authentication → Emails → Templates（需先設定自訂 SMTP）

| 範本 | 主旨 | 內容檔 |
|---|---|---|
| Magic link or OTP | 【汪喵回家】你的登入連結 | magic_link.html |
| Confirm sign up | 【汪喵回家】歡迎加入！請確認你的信箱 | confirm_signup.html |

SMTP（Resend）：主機 smtp.resend.com、連接埠 465、使用者名稱 resend、密碼＝Resend API 金鑰（站長自行貼上）、
寄件人 noreply@wangmiaotw.com、寄件人名稱 汪喵回家。

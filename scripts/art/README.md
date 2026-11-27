# 散步冒險的插圖（GPT 畫）

- 通用圖：`art/<名稱>.webp`（320×320 去背），清單由 index.html 的 `WA_IMG` 自動列出；改了圖要把 `WA_V` 加 1。
- 毛孩專屬可愛版：`art/pet/<pet_id>.webp`、`_atk`、`_hit`、`_win` 四張，並把 `pets.art` 設成 `/art/pet/<pet_id>`。
- 原稿：用 ChatGPT 一次畫一張 3×3（或 2×2）白底圖，暫存到 Storage `photos/sightings/zz-gameart/`，再跑 `art-pull` 工作流程抓進 `art-raw` 分支。
- 切圖：`python3 scripts/art/slice.py 原稿.webp 名稱1,名稱2,... 列數 欄數`（輸出到 out/）。

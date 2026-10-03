# 大學學習與畢業專題

長庚大學人工智慧學系 邱庭俞。這裡整理大學期間的畢業專題與課程作品。每個作品都標明是個人或小組完成，小組作品也寫出我負責的部分。

## 作品一覽

| 資料夾 | 內容 | 形式 | 我負責的部分 |
|---|---|---|---|
| [`畢業專題/ios_app`](畢業專題/ios_app) | 智慧相簿管理系統：在 iPhone 上以 MobileCLIP 離線完成照片語意搜尋與 AI 分類 | 四人小組 | iOS App 架構、照片與文字查詢前處理（含 Swift 版 CLIP BPE 分詞器）、AI 分類瀏覽、Agent 與抽象語意搜尋的 App 端接合 |
| [`平行程式設計期末`](平行程式設計期末) | N-body 重力模擬（Barnes-Hut）：Serial、OpenMP、MPI、MPI+OpenMP、Master-Worker 五種版本與效能實驗報告 | 個人 | 全部 |
| [`智慧物聯網 AIoT/Final Project`](智慧物聯網%20AIoT/Final%20Project) | 智慧路口行人安全系統：YOLOv8 偵測慢行行人，透過 SUMO 模擬延長綠燈 | 兩人小組 | YOLO 偵測、ByteTrack 追蹤與速度估計模組（`project/yolov8`） |
| [`智慧物聯網 AIoT/HW1`](智慧物聯網%20AIoT/HW1)、[`HW2`](智慧物聯網%20AIoT/HW2) | Q-learning、DQN 作業 | 個人 | 全部 |
| [`自然語言處理期末`](自然語言處理期末) | Kaggle「MAP – Charting Student Math Misunderstandings」 | 四人小組 | BGE 語意檢索模組（資料夾內只放我實作的部分） |
| [`多媒體資訊概論/HW1`](多媒體資訊概論/HW1)、[`HW2`](多媒體資訊概論/HW2) | DFT 濾波、HSI 影像處理 | 個人 | 全部 |

## 各作品說明

### 畢業專題：智慧相簿管理系統（2025–2026）
- 照片在手機上轉成 MobileCLIP 語意向量並存在本機 SQLite，使用者可用自然語言或語音搜尋，搜尋不需上傳雲端。
- 文字端在 Swift 中自行實作 CLIP 的 BPE 分詞器。
- 大量照片同時處理曾造成記憶體耗盡，改為序列批次處理解決。
- 初步測試：隨機 10 句查詢都找到對應照片；App 在 iPhone 上處理並分類 1,000 張照片約需 40.63 秒。
- 本專題延伸為 115 年度國科會大專學生研究計畫（115-2813-C-182-041-E），執行中。

### 平行程式設計期末：N-body 平行化
- 以 checksum 和 Serial 版本比對驗證正確性，並做粒子數、執行緒數、行程數、任務大小四組實驗。
- 在 N=10,000、4 processes × 4 threads 下，MPI+OpenMP 加速 6.27 倍；分析 N=50,000 時 MPI 比 OpenMP 慢的原因（每個行程重複建樹）。
- 詳見 `Report.pdf`。

### 智慧物聯網期末：智慧路口行人安全系統
- YOLOv8s 偵測行人，ByteTrack 追蹤，依位移估算步行速度並分成正常、慢行、危險三級。
- 慢行事件透過 HTTP API 送到組員的 SUMO／TraCI 模擬，延長行人綠燈。
- 詳見 `智慧物聯網期末報告.pdf`。

### 自然語言處理期末：Kaggle 學生數學迷思概念分類
- 組員以 DeBERTa-v3-base 建立分類模型；我負責加入 BGE 語意檢索：以 MNRL 微調 BGE-large（9,821 組訓練樣本），並設計 Global／Local 兩層代表向量，把搜尋範圍從 35 類縮小到平均 2～4 類。
- 結果：純 DeBERTa（組員）Public 0.90084 為最佳；加入檢索的各版本介於 0.80502～0.90071。
- 分析：BGE 的 Recall@3 為 99.94%，但 Recall@1 只有 71.90%，找得到候選卻排不準第一名；改用 hard negative 與任務指令重新微調後，融合分數從 0.90061 提升到 0.90071。

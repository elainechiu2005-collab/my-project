# API需要的格式

* **通訊協定**：`HTTP`
* **資料格式**：`application/json`

---

## 1. 領取運算任務 (Worker -> Master)
* **API 路徑**：`GET /api/task`
* **說明**：Worker 會不斷發送 GET 請求來要任務。如果目前沒有任務，Master 可回傳 404，Worker 會自行等待並重試。
* **Master 成功回傳 (200 OK) 的 JSON 格式**：
```json
{
  "task_id": "task-001",
  "prefix_path": [[0, 0], [1, 1]], 
  "remaining_points": [[12, 45], [55, 23], [89, 12]]
}
```
*(註：`prefix_path` 為已固定的前綴路徑，`remaining_points` 為需要 Worker 進行排列組合窮舉的剩餘點位。)*

---

## 2. 回傳計算結果 (Worker -> Master)
* **API 路徑**：`POST /api/result`
* **說明**：Worker 跑完該任務的所有排列組合後，會將最短距離與完整的最佳路徑回傳給 Master。
* **Worker 發送的 JSON 格式**：
```json
{
  "task_id": "task-001",
  "worker_id": "worker-1",
  "best_path": [[0, 0], [1, 1], [55, 23], [12, 45], [89, 12]],
  "min_distance": 288.39
}
```

---

## 3. 接收存活心跳 (Worker -> Master)
* **API 路徑**：`POST /api/heartbeat`
* **說明**：Worker 的背景執行緒會每秒發送一次心跳。Master 可用此機制判斷 Worker 是否斷線，若斷線需將該 `task_id` 重新派發。
* **Worker 發送的 JSON 格式**：
```json
{
  "worker_id": "worker-1",
  "timestamp": 1717435200.123
}
```

---

## 4. 接收硬體監控數據 (Worker -> Master)
* **API 路徑**：`POST /api/metrics`
* **說明**：Worker 的背景執行緒會每兩秒發送一次當前的精準 CPU 負載數據。
* **Worker 發送的 JSON 格式**：
```json
{
  "worker_id": "worker-1",
  "cpu_usage": 99.8
}
```
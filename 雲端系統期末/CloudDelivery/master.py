import asyncio
import json
import math
import uuid
import time
from fastapi import FastAPI, WebSocket
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from typing import Dict, List, Optional

app = FastAPI()

# 允許跨域請求
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 1. 任務佇列
memory_queue: Optional[asyncio.Queue] = None

# 2. 全局任務追蹤資料庫 (儲存所有切割後的子任務狀態)
tasks_db: Dict[str, dict] = {}

# 3. 節點健康度與監控數據
workers_status: Dict[str, dict] = {}

# 4. 全局最佳解追蹤
global_best = {
    "min_distance": float('inf'),
    "best_path": []
}

@app.on_event("startup")
async def startup_event():
    global memory_queue
    memory_queue = asyncio.Queue()

@app.get("/api/task")
async def get_task():
    """Worker 來要任務"""
    if memory_queue is None:
        raise RuntimeError("memory_queue 尚未初始化")

    while True:
        try:
            task = await asyncio.wait_for(memory_queue.get(), timeout=1.0)
            task_id = task["task_id"]
            if task_id not in tasks_db:
                continue

            # 檢查是否被取消
            if tasks_db[task_id]["status"] == "Cancelled":
                continue

            tasks_db[task_id]["status"] = "Processing"
            return task
            
        except asyncio.TimeoutError:
            from fastapi.responses import JSONResponse
            return JSONResponse(status_code=404, content={"message": "No tasks available"})

@app.post("/api/result")
async def post_result(data: dict):
    """Worker 傳回運算結果"""
    task_id = data.get("task_id")
    min_dist = data.get("min_distance")
    best_path = data.get("best_path")
    
    if task_id in tasks_db:
        tasks_db[task_id]["status"] = "Completed"
        
        # 更新全局最佳解
        if min_dist < global_best["min_distance"]:
            global_best["min_distance"] = min_dist
            global_best["best_path"] = best_path
            
    return {"status": "ok"}

@app.post("/api/heartbeat")
async def receive_heartbeat(data: dict):
    """接收 Worker 心跳"""
    worker_id = data.get("worker_id")
    if worker_id not in workers_status:
        workers_status[worker_id] = {"cpu_usage": 0}
    workers_status[worker_id]["last_seen"] = data.get("timestamp", time.time())
    return {"status": "ok"}

@app.post("/api/metrics")
async def receive_metrics(data: dict):
    """接收 Worker CPU 數據"""
    worker_id = data.get("worker_id")
    if worker_id not in workers_status:
         workers_status[worker_id] = {"last_seen": time.time()}
    workers_status[worker_id]["cpu_usage"] = data.get("cpu_usage")
    return {"status": "ok"}


import itertools

@app.post("/api/submit")
async def submit_job(data: dict):
    """前端送來 Canvas 點位，Master 進行切割並放入 Queue"""
    points = data.get("points", [])
    n = len(points)

    global_best["min_distance"] = float('inf')
    global_best["best_path"] = []

    
    start_point = points[0]
    other_points = points[1:]
    
    task_count = 0
    # 產生長度為 2 的排列作為 prefix 的一部分
    for perm in itertools.permutations(other_points, 2):
        task_id = f"job-{uuid.uuid4().hex[:6]}-{task_count}"
        
        # Prefix = [起點, 排列的第一點, 排列的第二點]
        prefix = [start_point] + list(perm)
        
        # Remaining = 剩下的所有點
        remaining = [p for p in other_points if p not in perm]
        
        task_data = {
            "task_id": task_id,
            "status": "Queued",
            "prefix_path": prefix,
            "remaining_points": remaining,
            "start_point": start_point # 告訴 Worker 起點在哪，方便計算閉環
        }
        
        tasks_db[task_id] = task_data
        await memory_queue.put(task_data)
        task_count += 1
        
    return {"message": f"任務已切割為 {task_count} 個子任務並加入排隊", "tasks_count": task_count}

@app.post("/api/cancel/{task_id}")
async def cancel_job(task_id: str):
    """前端取消特定任務"""
    if task_id in tasks_db and tasks_db[task_id]["status"] == "Queued":
        tasks_db[task_id]["status"] = "Cancelled"
        return {"message": f"任務 {task_id} 已取消"}
    return {"error": "找不到任務或任務已在執行/完成"}

@app.post("/api/reset")
async def reset_state():
    """前端清除點位時，同步清除後端的舊紀錄與佇列"""
    global_best["min_distance"] = float('inf')
    global_best["best_path"] = []
    tasks_db.clear()
    
    if memory_queue is not None:
        while not memory_queue.empty():
            try:
                memory_queue.get_nowait()
            except asyncio.QueueEmpty:
                break
                
    return {"status": "ok"}

@app.websocket("/ws/dashboard")
async def websocket_dashboard(websocket: WebSocket):
    """每 0.5 秒推播叢集狀態給前端"""
    await websocket.accept()
    try:
        while True:
            payload = {
                "workers": workers_status,
                "tasks": tasks_db,
                "global_best": {
                    "min_distance": None if global_best["min_distance"] == float('inf') else global_best["min_distance"],
                    "best_path": global_best["best_path"]
                }
            }
            await websocket.send_text(json.dumps(payload))
            await asyncio.sleep(0.5)
    except Exception:
        print("前端 WebSocket 連線中斷")
        
@app.get("/")
async def get_index():
    with open("index.html", "r", encoding="utf-8") as f:
        html_content = f.read()
    return HTMLResponse(content=html_content, status_code=200)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=80)
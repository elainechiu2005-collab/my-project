import os
import time
import threading
import subprocess
import requests
import math
import itertools
import re

WORKER_ID = os.getenv("WORKER_ID", "local-worker")
MASTER_URL = os.getenv("MASTER_URL", "http://localhost:80")

def send_heartbeat():
    while True:
        try:
            requests.post(f"{MASTER_URL}/api/heartbeat", json={"worker_id": WORKER_ID, "timestamp": time.time()})
        except Exception:
            pass 
        time.sleep(1)

def monitor_resources():
    while True:
        try:
            result = subprocess.run(["top", "-bn", "1", "-i", "-c"], capture_output=True, text=True)
            output = result.stdout

            cpu_match = re.search(r'%Cpu\(s\):\s+([\d\.]+)\s+us', output)
            
            if cpu_match:
                cpu_usage = float(cpu_match.group(1))
                requests.post(f"{MASTER_URL}/api/metrics", json={"worker_id": WORKER_ID, "cpu_usage": cpu_usage})
            else:
                pass
                
        except Exception as e:
            print(f"[{WORKER_ID}] 監控錯誤: {e}")
            
        time.sleep(2)

def calculate_tsp(prefix_path, remaining_points, start_point):
    min_distance = float('inf')
    best_path = None
    
    # 1. 預先計算 prefix 內部的距離
    prefix_distance = 0
    if len(prefix_path) > 1:
        for i in range(len(prefix_path) - 1):
            prefix_distance += math.dist(prefix_path[i], prefix_path[i+1])

    count = 0
    for perm in itertools.permutations(remaining_points):
        count += 1
        # 每算一小段休息一下，確保心跳能發送，並且讓 top 指令能抓到變化
        if count % 20000 == 0:
            time.sleep(0.001)

        current_full_path = list(prefix_path) + list(perm)
        
        # 2. 計算 prefix 最後一點 連接到 remaining 第一點的距離
        link_distance = 0
        if prefix_path and perm:
            link_distance = math.dist(prefix_path[-1], perm[0])

        # 3. 計算 remaining 內部的距離
        perm_distance = 0
        if len(perm) > 1:
            for i in range(len(perm) - 1):
                perm_distance += math.dist(perm[i], perm[i+1])

        # 4. 加上回到起點的距離 (閉環)
        return_distance = 0
        if current_full_path:
             return_distance = math.dist(current_full_path[-1], start_point)

        # 5. 總距離
        total_dist = prefix_distance + link_distance + perm_distance + return_distance
        
        if total_dist < min_distance:
            min_distance = total_dist
            best_path = current_full_path + [start_point]
            
    return best_path, min_distance

def main():
    print(f"[{WORKER_ID}] 系統啟動，初始化心跳與監控執行緒...")
    threading.Thread(target=send_heartbeat, daemon=True).start()
    threading.Thread(target=monitor_resources, daemon=True).start()
    
    while True:
        try:
            response = requests.get(f"{MASTER_URL}/api/task")
            if response.status_code == 200:
                task_data = response.json()
                task_id = task_data.get("task_id")
                prefix_path = task_data.get("prefix_path", [])
                remaining_points = task_data.get("remaining_points", [])
                start_point = task_data.get("start_point")
                if not task_id or not remaining_points:
                    time.sleep(1)
                    continue
                
                print(f"[{WORKER_ID}] 取得任務 {task_id}，開始計算剩餘 {len(remaining_points)} 點...")
                best_path, min_distance = calculate_tsp(prefix_path, remaining_points, start_point)
                
                requests.post(f"{MASTER_URL}/api/result", json={
                    "task_id": task_id,
                    "worker_id": WORKER_ID,
                    "best_path": best_path,
                    "min_distance": min_distance
                })
                print(f"[{WORKER_ID}] 任務 {task_id} 計算完成！")
            else:
                print(f"[{WORKER_ID}] 等待任務中 (Master 回傳狀態碼: {response.status_code})...")
                time.sleep(2)
        except requests.exceptions.ConnectionError:
            print(f"[{WORKER_ID}] 無法連線至 Master ({MASTER_URL})，等待重試...")
            time.sleep(2)
        except Exception as e:
            print(f"[{WORKER_ID}] 發生未知錯誤: {e}")
            time.sleep(2)

if __name__ == "__main__":
    main()
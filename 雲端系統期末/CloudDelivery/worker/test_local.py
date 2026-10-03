import math
import itertools
import time
import subprocess
import re
import threading
import random

# ==========================================
# 1. 把我們寫好的演算法貼過來
# ==========================================
def calculate_tsp(prefix_path, remaining_points):
    min_distance = float('inf')
    best_path = None
    
    prefix_distance = 0
    if len(prefix_path) > 1:
        for i in range(len(prefix_path) - 1):
            prefix_distance += math.dist(prefix_path[i], prefix_path[i+1])

    count = 0
    for perm in itertools.permutations(remaining_points):
        count += 1
        # 每算 10000 次稍微釋放一下 CPU，讓監控執行緒能做事
        if count % 10000 == 0:
            time.sleep(0.001)

        current_full_path = list(prefix_path) + list(perm)
        
        link_distance = 0
        if prefix_path and perm:
            link_distance = math.dist(prefix_path[-1], perm[0])

        perm_distance = 0
        if len(perm) > 1:
            for i in range(len(perm) - 1):
                perm_distance += math.dist(perm[i], perm[i+1])

        total_dist = prefix_distance + link_distance + perm_distance
        
        if total_dist < min_distance:
            min_distance = total_dist
            best_path = current_full_path
            
    return best_path, min_distance

# ==========================================
# 2. 獨立的監控測試函數
# ==========================================
def test_monitor():
    while True:
        try:
            result = subprocess.run(["top", "-bn", "1", "-i", "-c"], capture_output=True, text=True)
            output = result.stdout
            
            # 測試我們的 Regex 是否能在高負載下存活
            cpu_match = re.search(r'%Cpu\(s\):\s+([\d\.]+)\s+us', output)
            if cpu_match:
                cpu_usage = float(cpu_match.group(1))
                print(f"📊 [監控] 目前 CPU 使用率: {cpu_usage}%")
            else:
                print("⚠️ [錯誤] Regex 抓不到 CPU 數據！請檢查 top 輸出格式。")
        except Exception as e:
            pass
        time.sleep(1)

# ==========================================
# 3. 模擬發動攻擊 (壓力測試)
# ==========================================
if __name__ == "__main__":
    print("啟動背景 CPU 監控...")
    threading.Thread(target=test_monitor, daemon=True).start()
    
    # 隨機生成假座標點 (你可以調整數量，建議從 8 開始，慢慢加到 11)
    NUM_POINTS = 9
    print(f"\n🚀 準備產生 {NUM_POINTS} 個點位進行 O(N!) 運算...")
    
    # 假設 Master 給的前綴是固定的起點
    fake_prefix = [[0, 0]]
    # 剩下的點讓 Worker 算
    fake_remaining = [[random.randint(0, 100), random.randint(0, 100)] for _ in range(NUM_POINTS)]
    
    print(f"待計算剩餘點位: {fake_remaining}")
    print("🔥 運算開始！請觀察 CPU 是否飆升...\n")
    
    start_time = time.time()
    best_path, min_dist = calculate_tsp(fake_prefix, fake_remaining)
    end_time = time.time()
    
    print(f"\n✅ 運算完成！")
    print(f"⏱️ 耗時: {end_time - start_time:.2f} 秒")
    print(f"📏 最短距離: {min_dist:.2f}")
import cv2
import numpy as np

VIDEO_PATH = "testVideo.mov"

# 請設定您要框選的真實物理範圍 (例如斑馬線寬度 4m，長度 10m)
REAL_WIDTH_M  = 4.0  
REAL_HEIGHT_M = 10.0 

points = []

def click_event(event, x, y, flags, param):
    global points
    if event == cv2.EVENT_LBUTTONDOWN:
        points.append([x, y])
        cv2.circle(frame, (x, y), 5, (0, 0, 255), -1)
        cv2.imshow("Bird's-eye Calibration", frame)

        if len(points) == 4:
            src_pts = np.array(points, dtype=np.float32)
            # 建立真實物理坐標系 (放大 100 倍方便計算，1m = 100px)
            scale = 100
            dst_pts = np.array([
                [0, 0],
                [REAL_WIDTH_M * scale, 0],
                [REAL_WIDTH_M * scale, REAL_HEIGHT_M * scale],
                [0, REAL_HEIGHT_M * scale]
            ], dtype=np.float32)

            # 算出透視轉換矩陣並存檔
            H, _ = cv2.findHomography(src_pts, dst_pts)
            np.save("homography.npy", H)
            
            cv2.polylines(frame, [np.array(points)], True, (0, 255, 0), 2)
            cv2.imshow("Bird's-eye Calibration", frame)
            print("✅ 矩陣已成功儲存至 homography.npy！請按 ESC 離開。")

cap = cv2.VideoCapture(VIDEO_PATH)
ret, frame = cap.read()
cap.release()

if ret:
    print("👉 請按順序點擊斑馬線的 4 個頂點：【左上】 -> 【右上】 -> 【右下】 -> 【左下】")
    cv2.imshow("Bird's-eye Calibration", frame)
    cv2.setMouseCallback("Bird's-eye Calibration", click_event)
    cv2.waitKey(0)
    cv2.destroyAllWindows()
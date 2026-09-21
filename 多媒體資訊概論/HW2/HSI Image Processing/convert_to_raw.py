import numpy as np
from PIL import Image
import os

def convert_image_to_sequential_raw(input_filename, output_filename, target_size=(512, 512)):
    """
    讀取任意圖片 (JPG/PNG/BMP) -> Resize -> 轉成 Sequential Raw (RRR...GGG...BBB)
    """
    if not os.path.exists(input_filename):
        print(f"找不到檔案: {input_filename}")
        return

    try:
        # 1. 嘗試用 PIL 開啟圖片 (Pillow 會自動識別 JPG/PNG/BMP 等格式，忽略副檔名)
        img = Image.open(input_filename)
        
        # 2. 強制轉為 RGB 模式 (避免 RGBA 或 Grayscale)
        img = img.convert('RGB')
        
        # 3. 縮放至 512x512
        img = img.resize(target_size, Image.Resampling.LANCZOS)
        
        # 4. 轉為 NumPy Array (H, W, 3)
        img_array = np.array(img)
        
        # 5. 轉置為 Sequential Planar 格式 (3, H, W) -> (RRR...GGG...BBB...)
        # 這是作業要求的關鍵格式
        img_planar = img_array.transpose((2, 0, 1))
        
        # 6. 存為 .raw
        img_planar.tofile(output_filename)
        print(f"成功轉換: {input_filename} -> {output_filename} (Size: 512x512)")
        
    except Exception as e:
        print(f"無法轉換 {input_filename}: {e}")

def main():
    # 列出所有需要轉檔的檔案
    # 假設 1.raw 和 2.raw 是你手邊的原始圖片 (可能是 JPG 改名的)
    files_to_fix = ['1.raw', '2.raw']
    
    for f in files_to_fix:
        # 輸出檔名改為 "1_fixed.raw" 避免覆蓋原始檔
        output_name = f.replace('.raw', '_fixed.raw')
        convert_image_to_sequential_raw(f, output_name)

    print("\n轉換完成！請在主程式中使用 '_fixed.raw' 檔案。")

if __name__ == "__main__":
    main()
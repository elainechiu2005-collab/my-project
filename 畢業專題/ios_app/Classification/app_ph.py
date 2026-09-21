import os
import shutil
import time
import torch
import numpy as np
import pandas as pd
from PIL import Image
from transformers import CLIPProcessor, CLIPModel

if __name__ == '__main__':
    # ==========================================
    # 0. 核心參數與閾值設定 (在此調整尋找最佳閾值)
    # ==========================================
    THRESHOLD = 0.25        # 相似度信心度門檻 (建議從 0.20 ~ 0.28 開始測試)
    source_folder = 'myphone'  # 原始照片資料夾
    output_parent = 'myphone_classified25'  # 分類後的目標主資料夾
    unclassified_folder_name = '未分類'     # 低於閾值時放入的資料夾名稱

    # ==========================================
    # 1. 讀取 Excel 分類表與建立階層架構
    # ==========================================
    excel_path = '分類表.xlsx'
    
    if not os.path.exists(excel_path):
        print(f"❌ 錯誤：找不到分類表檔案 【{excel_path}】，請確認檔案路徑！")
        exit()
        
    print(f"📊 正在讀取 Excel 分類表：{excel_path}...")
    df_cat = pd.read_excel(excel_path)

    # 自動建立 { 大分類: [小分類1, 小分類2, ...] } 的 mapping
    category_hierarchy = df_cat.groupby('大分類')['小分類'].apply(lambda x: list(dict.fromkeys(x))).to_dict()

    # 建立「小分類 -> 大分類」的反向對照字典
    sub_to_main_mapping = {}
    all_sub_categories = []
    
    for main_cat, sub_cats in category_hierarchy.items():
        for sub_cat in sub_cats:
            sub_to_main_mapping[sub_cat] = main_cat
            if sub_cat not in all_sub_categories:
                all_sub_categories.append(sub_cat)

    print(f"✨ 成功解析階層架構！共包含 {len(category_hierarchy)} 個大分類、{len(all_sub_categories)} 個小分類。")

    # ==========================================
    # 2. 系統與模型初始化
    # ==========================================
    total_start_time = time.time()
    
    print("\n【系統初始化】正在載入 CLIP 模型與處理器...")
    init_start = time.time()
    
    model = CLIPModel.from_pretrained("openai/clip-vit-base-patch32")
    processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")
    
    print(f"✨ 模型載入完成，耗時: {time.time() - init_start:.2f} 秒")

    # ==========================================
    # 3. 方法一：小分類的多重 Prompt 擴充字典
    # ==========================================
    expanded_prompts = {
        'person': ["a photo of a person", "a portrait of a human", "a photo showing a person"],
        'group of people': ["a photo of a group of people", "multiple people together", "a crowd or group photo"],
        'selfie': ["a selfie photo of a person", "a front camera portrait photo", "a close-up selfie"],
        'baby': ["a photo of a baby or infant", "a cute little newborn baby", "a toddler child"],
        'cat': ["a photo of a cat", "a close-up of a cute kitty", "a pet feline cat"],
        'dog': ["a photo of a dog", "a friendly pet puppy or canine", "a dog sitting or playing"],
        'food': ["a photo of delicious food or meal", "a plate of tasty food or dish", "lunch or dinner"],
        'drink': ["a photo of a drink or beverage", "a cup of coffee or tea", "a glass with a liquid beverage"],
        'document or screenshot': ["a screenshot of a phone screen", "a scan or photo of a paper document, receipt", "a digital display screen"]
    }
    
    # 保持資料夾名稱乾淨（取代空符號）
    sub_folder_mapping = {sub_cat: str(sub_cat).replace(' ', '_') for sub_cat in all_sub_categories}

    # ==========================================
    # 4. 計算小分類的多重 Prompt 特徵 (Mean Pooling)
    # ==========================================
    print("\n👉 [步驟一]：正在利用【方法一：硬寫死多重 Prompt 融合】計算小分類標籤特徵...")
    text_start = time.time()
    
    X_text_norm_list = []
    
    for sub_cat in all_sub_categories:
        prompts = expanded_prompts.get(sub_cat, [f"a photo of a {sub_cat}"])
        inputs_text = processor(text=prompts, padding=True, return_tensors="pt")
        
        with torch.no_grad():
            text_outputs = model.get_text_features(**inputs_text)
            
            if hasattr(text_outputs, "pooler_output"):
                text_tensor = text_outputs.pooler_output
            else:
                text_tensor = text_outputs
                
            text_feats = text_tensor.detach().cpu().numpy()
            text_feats_norm = text_feats / np.linalg.norm(text_feats, axis=1, keepdims=True)
            mean_feat = np.mean(text_feats_norm, axis=0)
            mean_feat_norm = mean_feat / np.linalg.norm(mean_feat)
            X_text_norm_list.append(mean_feat_norm)
            
    X_text_norm = np.array(X_text_norm_list)
    print(f"✨ 文字特徵字典建置完成，耗時: {time.time() - text_start:.2f} 秒")

    # ==========================================
    # 5. 掃描原始圖片
    # ==========================================
    print(f"\n👉 [步驟二]：正在掃描 【{source_folder}】 資料夾...")
    valid_extensions = ('.jpg', '.jpeg', '.png', '.bmp', '.webp')
    image_paths = []
    
    if not os.path.exists(source_folder):
        print(f"❌ 錯誤：找不到名為 【{source_folder}】 的資料夾，請確認路徑！")
        exit()
        
    for root, dirs, files in os.walk(source_folder):
        for file in files:
            if file.lower().endswith(valid_extensions):
                image_paths.append(os.path.join(root, file))
                
    total_images = len(image_paths)
    print(f"✨ 掃描完成！共偵測到 {total_images} 張待分類的照片。")
    if total_images == 0:
        print("ℹ️ 資料夾內沒有支援的圖片檔案，程式結束。")
        exit()

    # ==========================================
    # 6. 逐張比對、閾值判斷與實體層級搬移
    # ==========================================
    print(f"\n👉 [步驟三]：開始進行智慧分類（目前門檻值 THRESHOLD = {THRESHOLD}）...")
    os.makedirs(output_parent, exist_ok=True)
    
    success_count = 0
    unclassified_count = 0
    loop_start_time = time.time()
    
    for idx, img_path in enumerate(image_paths):
        single_img_start = time.time()
        try:
            image = Image.open(img_path).convert("RGB")
            inputs_img = processor(images=image, return_tensors="pt")
            
            with torch.no_grad():
                img_outputs = model.get_image_features(**inputs_img)
                if hasattr(img_outputs, "pooler_output"):
                    img_tensor = img_outputs.pooler_output
                else:
                    img_tensor = img_outputs
                    
                img_feat_numpy = img_tensor.detach().cpu().numpy()
                X_img_norm = img_feat_numpy / np.linalg.norm(img_feat_numpy, axis=1, keepdims=True)
            
            # 計算與所有小分類標籤的相似度
            similarity = np.dot(X_img_norm, X_text_norm.T)[0]
            pred_idx = np.argmax(similarity)
            confidence = similarity[pred_idx]
            
            file_name = os.path.basename(img_path)
            single_img_elapsed = time.time() - single_img_start

            # 判斷是否達到門檻值 THRESHOLD
            if confidence >= THRESHOLD:
                pred_sub_cat = all_sub_categories[pred_idx]
                pred_main_cat = sub_to_main_mapping.get(pred_sub_cat, "其他")
                
                # 建立 大分類/小分類 的雙層資料夾結構
                sub_folder_name = sub_folder_mapping[pred_sub_cat]
                target_dir = os.path.join(output_parent, str(pred_main_cat), sub_folder_name)
                os.makedirs(target_dir, exist_ok=True)
                
                dest_path = os.path.join(target_dir, file_name)
                shutil.copy(img_path, dest_path)
                
                success_count += 1
                print(f" [{idx+1}/{total_images}] ✅ 成功歸類: {file_name} ──► 【{pred_main_cat} / {sub_folder_name}】 (信心度: {confidence:.4f}) | ⏱️ {single_img_elapsed:.2f}s")
            else:
                # 未達標放入「未分類」資料夾
                target_dir = os.path.join(output_parent, unclassified_folder_name)
                os.makedirs(target_dir, exist_ok=True)
                
                dest_path = os.path.join(target_dir, file_name)
                shutil.copy(img_path, dest_path)
                
                unclassified_count += 1
                print(f" [{idx+1}/{total_images}] ⚠️ 未達門檻: {file_name} ──► 移至【{unclassified_folder_name}】 (最高信心度僅: {confidence:.4f} < {THRESHOLD}) | ⏱️ {single_img_elapsed:.2f}s")
            
        except Exception as e:
            print(f" ❌ 無法處理照片 {img_path}，跳過。錯誤原因: {e}")

    # ==========================================
    # 7. 總結統計與尋找最佳閾值建議
    # ==========================================
    total_elapsed_time = time.time() - total_start_time
    avg_time_per_image = (time.time() - loop_start_time) / total_images if total_images > 0 else 0
    
    print("\n" + "="*60)
    print("📊 【相簿智慧實體分類工作完成！】")
    print(f" ⚙️ 設定門檻值 (THRESHOLD)：{THRESHOLD}")
    print(f" 📂 原始目錄：{source_folder}")
    print(f" 📂 分類後新目錄：{os.path.abspath(output_parent)}")
    print(f" ✅ 成功分類照片：{success_count} 張 ({success_count/total_images*100:.1f}%)")
    print(f" ⚠️ 歸類未分類照片：{unclassified_count} 張 ({unclassified_count/total_images*100:.1f}%)")
    print(f" ⏱️ 總執行時間：{total_elapsed_time:.2f} 秒")
    print(f" ⚡ 平均處理速度：{avg_time_per_image:.2f} 秒 / 張")
    print("="*60)
    print("💡 尋找最佳閾值提示：若『未分類』照片過多，可調低 THRESHOLD；若誤判過多，可調高 THRESHOLD。")
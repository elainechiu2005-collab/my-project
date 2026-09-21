import osmnx as ox
import os

PROJECT_PATH = r"D:\長庚\大三下\智慧物聯網\project"
os.chdir(PROJECT_PATH)

LAT = 25.0418   # 改這裡
LON = 121.5435  # 改這裡
DIST = 400      # 改大一點

print(f"正在下載路網... 中心點：({LAT}, {LON}), 範圍：{DIST}m")

# 關鍵修正：加這兩個設定
ox.settings.all_oneway = True       # 儲存 OSM XML 必須設這個
ox.settings.simplify = False        # 不簡化圖形，保留原始節點

G = ox.graph_from_point(
    (LAT, LON),
    dist=DIST,
    network_type="drive",
    simplify=False          # ✅ 這裡也要加
)

output_file = os.path.join(PROJECT_PATH, "taipei.osm")
ox.save_graph_xml(G, filepath=output_file)

print(f"✅ 路網下載完成！")
print(f"   節點數量: {len(G.nodes)}")
print(f"   道路數量: {len(G.edges)}")
print(f"   儲存位置: {output_file}")

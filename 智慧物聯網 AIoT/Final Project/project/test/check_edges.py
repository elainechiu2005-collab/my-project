import sumolib

net = sumolib.net.readNet(r"D:\長庚\大三下\智慧物聯網\project\taipei.net.xml")

print("主要幹道 Edge 清單（長度 > 50m）:")
print(f"{'Edge ID':<45} {'長度':>8}  {'車道數':>6}")
print("-" * 65)

edges = sorted(net.getEdges(), key=lambda e: e.getLength(), reverse=True)
for edge in edges[:20]:  # 只印前20條最長的道路
    if not edge.getID().startswith(":"):  # 排除內部連接邊
        print(f"{edge.getID():<45} {edge.getLength():>8.1f}m  {edge.getLaneNumber():>6}車道")

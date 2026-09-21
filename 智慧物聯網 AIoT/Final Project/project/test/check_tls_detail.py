import sumolib

net = sumolib.net.readNet(r"D:\長庚\大三下\智慧物聯網\project\taipei.net.xml")
tls_list = net.getTrafficLights()

print(f"找到 {len(tls_list)} 個號誌\n")
print(f"{'號誌 ID':<60} {'位置'}")
print("-" * 90)

for tls in tls_list:
    try:
        # 用 getEdges() 取得該號誌控制的道路，再取得道路的節點座標
        edges = tls.getEdges()
        if edges:
            edge = list(edges)[0]
            # 取道路的 from 節點座標
            node = edge.getFromNode()
            x, y = node.getCoord()
            lon, lat = net.convertXY2LonLat(x, y)
            print(f"{tls.getID():<60} lat:{lat:.5f}  lon:{lon:.5f}")
        else:
            print(f"{tls.getID():<60} (無法取得座標)")
    except Exception as e:
        print(f"{tls.getID():<60} 錯誤: {e}")

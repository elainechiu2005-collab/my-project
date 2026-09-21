import traci
import sys
import os

os.environ.setdefault("SUMO_HOME", r"C:\Program Files (x86)\Eclipse\Sumo")
sys.path.append(os.path.join(os.environ["SUMO_HOME"], "tools"))

sumo_cmd = [
    "sumo",
    "-c", r"D:\長庚\大三下\智慧物聯網\project\taipei_sim.sumocfg",
    "--no-warnings"
]

traci.start(sumo_cmd)
traci.simulationStep()

tls_list = traci.trafficlight.getIDList()
print("=" * 60)
for tls_id in tls_list:
    logic = traci.trafficlight.getAllProgramLogics(tls_id)[0]
    print(f"號誌 {tls_id}  →  Phase 數量：{len(logic.phases)}")
    for i, phase in enumerate(logic.phases):
        print(f"    Phase {i}：{phase.duration}s  燈號：{phase.state}")
    print()

traci.close()
print("完成！")

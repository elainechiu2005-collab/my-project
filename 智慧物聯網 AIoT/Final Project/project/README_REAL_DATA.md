# Real-Data SUMO Workflow

1. Run `python prepare_real_sumo.py --force-download` to fetch official Taipei data and generate SUMO inputs.
2. Inspect `data/generated/pedestrian_survey_status.json` to see whether the latest official pedestrian survey covers `IJHM7`.
3. If the survey does not cover the intersection, fill `data/manual/pedestrian_counts.csv` with your own validated field counts before claiming real pedestrian flow.
4. For a one-click Windows launch, run `launch_sumo_yolo.cmd`.
   - It starts the SUMO controller, the YOLO server, and the Vite dashboard.
   - It opens the dashboard on the right-most display in browser app mode so it fills that screen.
   - It opens the YOLO raw MJPEG stream on the other screen at `http://127.0.0.1:5173/raw`.
   - If your display layout is unusual, you can still tweak the window placement parameters in `launch_sumo_yolo.ps1`.
5. When you want to shut everything down at once, run `stop_sumo_yolo.cmd`.
   - It closes the dashboard, the raw stream window, the YOLO server, and the SUMO controller.
6. If you prefer manual startup, run `python traci_control.py --clock 07:00 --sumo-binary sumo-gui` first, then start the YOLO server and dashboard separately.
7. Send YOLOv8 events to `http://127.0.0.1:8765/events` with JSON like:

```json
{
  "intersection_id": "IJHM7",
  "avg_speed_mps": 0.72,
  "slow_pedestrian": true,
  "ttl_seconds": 20,
  "crossing_edge": "506322861#1",
  "track_ids": ["cameraA-0001"]
}
```

8. While the bridge is running, YOLO pedestrian counts are auto-aggregated and written to:
   - `data/generated/yolo_pedestrian_counts.csv`
   - `data/generated/yolo_pedestrian_state.json`
   - `data/manual/pedestrian_counts.csv` when that row is not protected by `official_survey` or `field_count`
9. Real-time event logs are written to `data/generated/traci_event_log.txt`. When a slow pedestrian actually causes an extension, you should see a line like:

```text
[ 123.0s] extended phase 5 by 10s for crossing_edge=506322861#1 remaining_before=7.0s
```

Notes:
- Vehicle flows are built from official Taipei `VD` section data near the study area.
- Signal timing is built from the official Taipei timing-plan and timing-schedule datasets for `IJHM7`.
- Pedestrian flows are considered real measured data when `source_kind` is `official_survey`, `field_count`, or `yolo_baseline`.
- `official_survey` remains the only official government source; `yolo_baseline` is your own measured baseline.

YOLOv8 HTTP payload contract:

```json
{
  "intersection_id": "IJHM7",
  "camera_id": "cam_phase5",
  "event_time": 1714550400.0,
  "crossing_edge": "506322861#1",
  "track_ids": ["track-001"],
  "avg_speed_mps": 0.72,
  "slow_pedestrian": true,
  "pedestrian_count": 1,
  "age_group": "elderly",
  "ttl_seconds": 20,
  "bbox_xyxy": [100, 200, 180, 340]
}
```

Field rules:
- Required: `intersection_id`, `avg_speed_mps`
- Strongly recommended: `crossing_edge`, `track_ids`
- `track_ids` should stay stable for the same person across frames so duplicate counting can be suppressed.
- `crossing_edge` currently maps `405980657#1 -> phase 0` and `506322861#1 -> phase 5`.
- If your camera cannot identify a crossing edge, you can send `target_phase` instead, but `crossing_edge` is preferred.
- If you want to bypass the camera-to-crossing mapping entirely, the YOLO launcher also accepts `--target-phase <index>` and will send that directly to SUMO.

Bridge helper scripts:
- `python yolo_http_adapter_example.py` sends one sample event immediately.
- `python yolo_team_bridge.py --demo` sends three spaced demo detections.
- `python yolo_team_bridge.py --jsonl detections.jsonl --camera-id cam_phase5` replays detections from a teammate-exported JSONL file.

If you are in Windows `cmd.exe` instead of PowerShell:
- Use `type data\generated\traci_event_log.txt` to view the event log.
- Or use `powershell -Command "Get-Content data\generated\traci_event_log.txt"`.

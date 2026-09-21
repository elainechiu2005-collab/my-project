from __future__ import annotations

import json
import time
import urllib.request


SUMO_API_URL = "http://127.0.0.1:8765/events"
INTERSECTION_ID = "IJHM7"

# Map each camera/ROI to the SUMO crossing edge that should receive the event.
# Current calibrated mappings:
# - "cam_phase0" -> crossing_edge "405980657#1" -> SUMO phase 0 pedestrian group
# - "cam_phase5" -> crossing_edge "506322861#1" -> SUMO phase 5 pedestrian group
CAMERA_TO_CROSSING_EDGE = {
    "cam_phase0": "405980657#1",
    "cam_phase5": "506322861#1",
}


def post_event(payload: dict) -> str:
    request = urllib.request.Request(
        SUMO_API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return response.read().decode("utf-8")


def build_payload(
    *,
    track_id: str,
    camera_id: str,
    avg_speed_mps: float,
    is_elderly: bool,
    bbox_xyxy: list[float] | None = None,
) -> dict:
    crossing_edge = CAMERA_TO_CROSSING_EDGE[camera_id]
    return {
        "intersection_id": INTERSECTION_ID,
        "camera_id": camera_id,
        "event_time": time.time(),
        "crossing_edge": crossing_edge,
        "track_ids": [track_id],
        "avg_speed_mps": round(avg_speed_mps, 3),
        "slow_pedestrian": avg_speed_mps < 0.9 or is_elderly,
        "pedestrian_count": 1,
        "age_group": "elderly" if is_elderly else "adult",
        "ttl_seconds": 20,
        "bbox_xyxy": bbox_xyxy or [],
    }


def on_yolo_detection(track_id: str, camera_id: str, avg_speed_mps: float, is_elderly: bool) -> None:
    payload = build_payload(
        track_id=track_id,
        camera_id=camera_id,
        avg_speed_mps=avg_speed_mps,
        is_elderly=is_elderly,
    )
    response_text = post_event(payload)
    print(f"Posted {payload['track_ids'][0]} from {camera_id}: {response_text}")


if __name__ == "__main__":
    # Replace this block with your teammate's YOLOv8 inference loop.
    on_yolo_detection(
        track_id="demo-track-001",
        camera_id="cam_phase5",
        avg_speed_mps=0.72,
        is_elderly=True,
    )

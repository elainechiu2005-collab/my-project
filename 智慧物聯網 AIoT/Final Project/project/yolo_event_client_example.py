import json
import urllib.request


payload = {
    "intersection_id": "IJHM7",
    "avg_speed_mps": 0.72,
    "slow_pedestrian": True,
    "ttl_seconds": 20,
    "crossing_edge": "506322861#1",
    "track_ids": ["demo-track-001"]
}

request = urllib.request.Request(
    "http://127.0.0.1:8765/events",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)

with urllib.request.urlopen(request, timeout=10) as response:
    print(response.read().decode("utf-8"))

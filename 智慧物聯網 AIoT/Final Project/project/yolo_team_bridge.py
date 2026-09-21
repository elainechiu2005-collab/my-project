from __future__ import annotations

import argparse
import json
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Iterator


SUMO_API_URL = "http://127.0.0.1:8765/events"
INTERSECTION_ID = "IJHM7"

# Map each camera or ROI to the SUMO pedestrian crossing that should receive the event.
CAMERA_TO_CROSSING_EDGE = {
    "cam_phase0": "405980657#1",
    "cam_phase5": "506322861#1",
}


@dataclass
class TeammateDetection:
    track_id: str
    camera_id: str
    avg_speed_mps: float
    is_elderly: bool
    crossing_edge: str = ""
    target_phase: int | None = None
    bbox_xyxy: list[float] = field(default_factory=list)
    confidence: float = 1.0
    pedestrian_count: int = 1
    event_time: float = 0.0

    def with_default_time(self) -> "TeammateDetection":
        if self.event_time > 0:
            return self
        return TeammateDetection(
            track_id=self.track_id,
            camera_id=self.camera_id,
            avg_speed_mps=self.avg_speed_mps,
            is_elderly=self.is_elderly,
            crossing_edge=self.crossing_edge,
            target_phase=self.target_phase,
            bbox_xyxy=self.bbox_xyxy,
            confidence=self.confidence,
            pedestrian_count=self.pedestrian_count,
            event_time=time.time(),
        )


class SumoHttpPublisher:
    def __init__(self, api_url: str, intersection_id: str, ttl_seconds: int = 20) -> None:
        self.api_url = api_url
        self.intersection_id = intersection_id
        self.ttl_seconds = ttl_seconds

    def post_detection(self, detection: TeammateDetection) -> str:
        payload = self._build_payload(detection.with_default_time())
        request = urllib.request.Request(
            self.api_url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.read().decode("utf-8")

    def _build_payload(self, detection: TeammateDetection) -> dict:
        crossing_edge = detection.crossing_edge.strip()
        if not crossing_edge and detection.target_phase is None:
            try:
                crossing_edge = CAMERA_TO_CROSSING_EDGE[detection.camera_id]
            except KeyError as exc:
                known = ", ".join(sorted(CAMERA_TO_CROSSING_EDGE))
                raise KeyError(f"Unknown camera_id '{detection.camera_id}'. Known camera_ids: {known}") from exc

        return {
            "intersection_id": self.intersection_id,
            "camera_id": detection.camera_id,
            "event_time": detection.event_time,
            **({"crossing_edge": crossing_edge} if crossing_edge else {}),
            **({"target_phase": detection.target_phase} if detection.target_phase is not None else {}),
            "track_ids": [detection.track_id],
            "avg_speed_mps": round(detection.avg_speed_mps, 3),
            "slow_pedestrian": detection.avg_speed_mps < 0.9 or detection.is_elderly,
            "pedestrian_count": detection.pedestrian_count,
            "age_group": "elderly" if detection.is_elderly else "adult",
            "ttl_seconds": self.ttl_seconds,
            "bbox_xyxy": detection.bbox_xyxy,
            "confidence": round(detection.confidence, 4),
        }


def detection_from_raw(raw: dict, default_camera_id: str | None = None) -> TeammateDetection:
    track_id = str(raw.get("track_id", raw.get("trackId", raw.get("id", "")))).strip()
    if not track_id:
        raise ValueError(f"Missing track_id in YOLO result: {raw}")

    camera_id = str(raw.get("camera_id", default_camera_id or "")).strip()
    if not camera_id:
        raise ValueError(f"Missing camera_id in YOLO result: {raw}")

    avg_speed_mps = float(raw.get("avg_speed_mps", raw.get("speed_mps", raw.get("speed", 0.0))))

    age_group = str(raw.get("age_group", "")).strip().lower()
    is_elderly = bool(raw.get("is_elderly", raw.get("elderly", age_group == "elderly")))

    crossing_edge = str(raw.get("crossing_edge", "")).strip()
    target_phase_raw = raw.get("target_phase")
    target_phase = None
    if target_phase_raw is not None and str(target_phase_raw).strip() != "":
        target_phase = int(target_phase_raw)
    bbox = raw.get("bbox_xyxy", raw.get("bbox", []))
    if bbox is None:
        bbox = []
    bbox_xyxy = [float(value) for value in bbox]

    confidence = float(raw.get("confidence", raw.get("conf", 1.0)))
    pedestrian_count = int(raw.get("pedestrian_count", raw.get("count", 1)))
    event_time = float(raw.get("event_time", 0.0))

    return TeammateDetection(
        track_id=track_id,
        camera_id=camera_id,
        avg_speed_mps=avg_speed_mps,
        is_elderly=is_elderly,
        crossing_edge=crossing_edge,
        target_phase=target_phase,
        bbox_xyxy=bbox_xyxy,
        confidence=confidence,
        pedestrian_count=pedestrian_count,
        event_time=event_time,
    )


def iter_jsonl_results(path: Path, default_camera_id: str | None = None) -> Iterator[TeammateDetection]:
    with path.open("r", encoding="utf-8") as fh:
        for line_number, line in enumerate(fh, 1):
            stripped = line.strip()
            if not stripped:
                continue
            raw = json.loads(stripped)
            try:
                yield detection_from_raw(raw, default_camera_id=default_camera_id)
            except Exception as exc:
                print(f"Skip invalid JSONL line {line_number}: {exc}")


def iter_demo_results(camera_id: str) -> Iterator[TeammateDetection]:
    sample_track_ids = ["demo-001", "demo-002", "demo-003"]
    sample_speeds = [0.72, 1.15, 0.81]
    sample_elderly = [True, False, True]
    for index, track_id in enumerate(sample_track_ids):
        yield TeammateDetection(
            track_id=track_id,
            camera_id=camera_id,
            avg_speed_mps=sample_speeds[index],
            is_elderly=sample_elderly[index],
            crossing_edge=CAMERA_TO_CROSSING_EDGE[camera_id],
            bbox_xyxy=[100 + index * 5, 200, 180 + index * 5, 340],
        )
        time.sleep(1.0)


def run_bridge(publisher: SumoHttpPublisher, detections: Iterable[TeammateDetection]) -> None:
    for detection in detections:
        response_text = publisher.post_detection(detection)
        print(
            f"Posted track_id={detection.track_id} camera_id={detection.camera_id} "
            f"speed={detection.avg_speed_mps:.2f} elderly={detection.is_elderly} -> {response_text}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Bridge teammate YOLO detections to the SUMO HTTP API.")
    parser.add_argument("--api-url", default=SUMO_API_URL)
    parser.add_argument("--intersection-id", default=INTERSECTION_ID)
    parser.add_argument("--camera-id", default="cam_phase5", help="Default camera id if the input data does not provide one.")
    parser.add_argument("--jsonl", default=None, help="Read teammate detections from a JSONL file.")
    parser.add_argument("--demo", action="store_true", help="Send three demo detections to the SUMO API.")
    args = parser.parse_args()

    if not args.demo and not args.jsonl:
        raise SystemExit("Choose one input mode: `--demo` or `--jsonl <file>`.")

    publisher = SumoHttpPublisher(
        api_url=args.api_url,
        intersection_id=args.intersection_id,
    )

    if args.demo:
        run_bridge(publisher, iter_demo_results(args.camera_id))
        return

    jsonl_path = Path(args.jsonl)
    if not jsonl_path.exists():
        raise SystemExit(f"JSONL file not found: {jsonl_path}")
    run_bridge(publisher, iter_jsonl_results(jsonl_path, default_camera_id=args.camera_id))


if __name__ == "__main__":
    main()

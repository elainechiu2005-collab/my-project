from __future__ import annotations

import argparse
import asyncio
import base64
import json
import queue
import sys
import threading
import time
from pathlib import Path

import cv2
import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from tracker import CctvSnapshotSource, PedestrianTracker, THR_NORMAL, THR_SLOW
from yolo_team_bridge import SumoHttpPublisher, TeammateDetection


TAIWAN_CCTV_URL = "https://cctv.freeway.gov.tw/LiveImages/HP1.jpg"
DEFAULT_VIDEO_PATH = Path(__file__).resolve().parent / "testVideo.mov"


parser = argparse.ArgumentParser()
parser.add_argument("--source", default=str(DEFAULT_VIDEO_PATH))
parser.add_argument("--ppm", type=float, default=175.0)
parser.add_argument("--conf", type=float, default=0.30)
parser.add_argument("--host", default="0.0.0.0")
parser.add_argument("--port", type=int, default=8000)
parser.add_argument("--sumo-api", default="http://127.0.0.1:8765/events")
parser.add_argument("--intersection-id", default="IJHM7")
parser.add_argument("--camera-id", default="cam_phase5")
parser.add_argument("--crossing-edge", default="", help="Optional pedestrian crossing edge override.")
parser.add_argument(
    "--target-phase",
    type=int,
    default=None,
    help="Optional SUMO pedestrian phase index to target directly.",
)
parser.add_argument("--event-ttl-seconds", type=int, default=20)
parser.add_argument(
    "--elderly-speed-threshold",
    type=float,
    default=0.9,
    help="Fallback threshold for sending a SUMO alert when a pedestrian is slow.",
)
args, _ = parser.parse_known_args()


raw_source = str(args.source)
if raw_source.lower() == "cctv":
    _cctv_src = CctvSnapshotSource(TAIWAN_CCTV_URL, refresh=0.5)
    _use_cctv = True
    video_source = 0
else:
    _use_cctv = False
    video_source = int(raw_source) if raw_source.isdigit() else str(Path(raw_source).expanduser())


tracker = PedestrianTracker(
    source=video_source if not _use_cctv else 0,
    pixels_per_m=args.ppm,
    conf_thresh=args.conf,
    roi=None,
    log_path="speed_log.csv",
)

if _use_cctv:
    tracker.fps = _cctv_src.fps
    tracker.speed_est.fps = _cctv_src.fps


sumo_publisher = SumoHttpPublisher(
    api_url=args.sumo_api,
    intersection_id=args.intersection_id,
    ttl_seconds=args.event_ttl_seconds,
)


_lock_frame = threading.Lock()
_lock_tracks = threading.Lock()
_latest_frame: np.ndarray | None = None
_latest_tracks: list[dict] = []
_latest_inference_frame: np.ndarray | None = None
_frame_dims: dict[str, int] = {"width": 640, "height": 480}

_frame_queue: queue.Queue = queue.Queue(maxsize=2)
_video_looped = False
_recently_published: dict[str, float] = {}


def _track_is_elderly(track: dict) -> bool:
    age_group = str(track.get("age_group", "")).strip().lower()
    return bool(track.get("is_elderly") or track.get("elderly") or age_group == "elderly")


def _track_to_detection(track: dict, now: float) -> TeammateDetection:
    x1, y1, bw, bh = track["bbox"]
    crossing_edge = str(args.crossing_edge).strip()
    return TeammateDetection(
        track_id=str(track["id"]),
        camera_id=args.camera_id,
        avg_speed_mps=float(track["speed"]),
        is_elderly=_track_is_elderly(track),
        crossing_edge=crossing_edge,
        target_phase=args.target_phase,
        bbox_xyxy=[float(x1), float(y1), float(x1 + bw), float(y1 + bh)],
        confidence=float(track.get("confidence", 1.0)),
        pedestrian_count=int(track.get("pedestrian_count", 1)),
        event_time=now,
    )


def _should_publish_track(track: dict, now: float) -> bool:
    if not track.get("confirmed", True):
        return False

    track_id = str(track.get("id", "")).strip()
    if not track_id:
        return False

    speed = float(track.get("speed", 0.0))
    elderly = _track_is_elderly(track)
    slow = speed < args.elderly_speed_threshold or str(track.get("status", "")).lower() in {"slow", "danger"}
    if not (elderly or slow):
        return False

    key = f"{args.camera_id}:{track_id}"
    last_sent_at = _recently_published.get(key)
    if last_sent_at is not None and now - last_sent_at < args.event_ttl_seconds:
        return False
    return True


def send_to_sumo(tracks: list[dict]) -> None:
    now = time.time()
    for track in tracks:
        if not _should_publish_track(track, now):
            continue

        detection = _track_to_detection(track, now)
        try:
            response_text = sumo_publisher.post_detection(detection)
        except Exception as exc:  # noqa: BLE001
            print(f"[SUMO] failed to post track_id={detection.track_id}: {exc}")
            continue

        _recently_published[f"{args.camera_id}:{detection.track_id}"] = now
        reason = "elderly" if detection.is_elderly else "slow"
        print(
            f"[SUMO] posted track_id={detection.track_id} camera_id={detection.camera_id} "
            f"reason={reason} speed={detection.avg_speed_mps:.2f} -> {response_text}"
        )


def reader_loop() -> None:
    global _latest_frame, _frame_dims, _video_looped

    video_fps = tracker.cap.get(cv2.CAP_PROP_FPS) or 30.0
    frame_delay = 1.0 / video_fps

    while True:
        loop_start = time.time()

        if _use_cctv:
            frame = _cctv_src.read()
            if frame is None:
                time.sleep(0.1)
                continue
        else:
            if tracker._loop_if_file():
                _video_looped = True
            ret, frame = tracker.cap.read()
            if not ret:
                time.sleep(0.05)
                continue

        tracker.frame_count += 1
        frame_index = tracker.frame_count

        with _lock_frame:
            _latest_frame = frame.copy()
        height, width = frame.shape[:2]
        _frame_dims.update({"width": width, "height": height})

        if not _frame_queue.full():
            _frame_queue.put((frame.copy(), frame_index))

        elapsed = time.time() - loop_start
        wait_time = frame_delay - elapsed
        if wait_time > 0:
            time.sleep(wait_time)


def inference_loop() -> None:
    global _latest_tracks, _latest_inference_frame, _video_looped

    while True:
        try:
            frame, frame_index = _frame_queue.get(timeout=1.0)
        except queue.Empty:
            continue

        if _video_looped:
            _video_looped = False
            try:
                if hasattr(tracker.yolo, "predictor") and tracker.yolo.predictor is not None:
                    for tracker_impl in tracker.yolo.predictor.trackers:
                        tracker_impl.reset()
            except Exception:
                pass

            from tracker import SpeedEstimator

            tracker.speed_est = SpeedEstimator(
                pixels_per_meter=tracker.speed_est.ppm,
                fps=tracker.fps,
            )
            tracker._trails.clear()
            tracker._last_track.clear()
            tracker._ghost_age.clear()
            with _lock_tracks:
                _latest_tracks = []
            print("[Tracker] video loop detected, reset tracker state")

        frame_h, frame_w = frame.shape[:2]
        if tracker.roi is not None:
            roi_rx1 = tracker.roi[0] * frame_w
            roi_ry1 = tracker.roi[1] * frame_h
            roi_rx2 = tracker.roi[2] * frame_w
            roi_ry2 = tracker.roi[3] * frame_h
        else:
            roi_rx1, roi_ry1, roi_rx2, roi_ry2 = 0, 0, frame_w, frame_h

        results = tracker.yolo.track(
            frame,
            classes=[0],
            conf=tracker.conf_thresh,
            imgsz=640,
            iou=0.45,
            verbose=False,
            persist=True,
            tracker="bytetrack.yaml",
        )

        active_ids: list[int] = []
        track_results: list[dict] = []

        if results and results[0].boxes.id is not None:
            for box in results[0].boxes:
                if box.id is None:
                    continue

                x1, y1, x2, y2 = box.xyxy[0].cpu().numpy().tolist()
                bw, bh = x2 - x1, y2 - y1
                cx = (x1 + x2) / 2
                cy = (y1 + y2) / 2
                aspect = bh / max(bw, 1)
                area = bw * bh

                if not (aspect > 0.4 and area > 800 and bw < frame_w * 0.25):
                    continue

                if not (roi_rx1 <= cx <= roi_rx2 and roi_ry1 <= cy <= roi_ry2):
                    continue

                tid = int(box.id[0])
                x1_i, y1_i, bw_i, bh_i = int(x1), int(y1), int(bw), int(bh)
                cx_i, cy_i = int(cx), int(cy)

                speed = tracker.speed_est.update(tid, cx, cy, frame_index)
                tracker._trails[tid].append([cx_i, cy_i])

                result = {
                    "id": tid,
                    "bbox": [x1_i, y1_i, bw_i, bh_i],
                    "center": [cx_i, cy_i],
                    "speed": speed,
                    "status": tracker._status(speed),
                    "trajectory": list(tracker._trails[tid]),
                    "confirmed": True,
                }
                result["is_elderly"] = _track_is_elderly(result)
                result["age_group"] = "elderly" if result["is_elderly"] else "adult"

                active_ids.append(tid)
                track_results.append(result)
                tracker._last_track[tid] = result
                tracker._ghost_age[tid] = 0
                tracker._log_track(result, frame_index)

        tracker._process_ghosts(active_ids, track_results)
        track_results = [
            r
            for r in track_results
            if roi_rx1 <= r["center"][0] <= roi_rx2 and roi_ry1 <= r["center"][1] <= roi_ry2
        ]
        tracker.speed_est.purge(active_ids)
        tracker._last_track_results = track_results

        annotated_frame = results[0].plot() if results else frame.copy()
        if tracker.roi is not None:
            cv2.rectangle(
                annotated_frame,
                (int(roi_rx1), int(roi_ry1)),
                (int(roi_rx2), int(roi_ry2)),
                (0, 200, 255),
                2,
            )
            cv2.putText(
                annotated_frame,
                "ROI",
                (int(roi_rx1) + 4, int(roi_ry1) + 20),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.65,
                (0, 200, 255),
                2,
            )

        with _lock_frame:
            _latest_inference_frame = annotated_frame

        with _lock_tracks:
            _latest_tracks = track_results

        send_to_sumo(track_results)


threading.Thread(target=reader_loop, daemon=True, name="reader").start()
threading.Thread(target=inference_loop, daemon=True, name="inference").start()


app = FastAPI(title="Smart Intersection Backend")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def _mjpeg_generator():
    while True:
        with _lock_frame:
            frame = _latest_inference_frame
        if frame is None:
            time.sleep(0.05)
            continue

        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 65])
        if ok:
            yield (
                b"--frame\r\n"
                b"Content-Type: image/jpeg\r\n\r\n"
                + buf.tobytes()
                + b"\r\n"
            )
        time.sleep(1 / 25)


@app.get("/video_feed")
def video_feed():
    return StreamingResponse(
        _mjpeg_generator(),
        media_type="multipart/x-mixed-replace; boundary=frame",
    )


def _build_payload(tracks: list[dict]) -> dict:
    confirmed = [track for track in tracks if track.get("confirmed", True)]
    speeds = [track["speed"] for track in confirmed if track["speed"] > 0.0]
    danger_n = sum(1 for speed in speeds if speed < THR_SLOW)
    slow_n = sum(1 for speed in speeds if THR_SLOW <= speed < THR_NORMAL)
    elderly_n = sum(1 for track in confirmed if _track_is_elderly(track))

    b64_frame = ""
    with _lock_frame:
        frame = _latest_frame
    if frame is not None:
        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 65])
        if ok:
            b64_frame = base64.b64encode(buf.tobytes()).decode()

    return {
        "frame_b64": b64_frame,
        "frame_dims": _frame_dims,
        "frame_count": tracker.frame_count,
        "fps": round(tracker.fps, 1),
        "tracks": tracks,
        "stats": {
            "count": len(confirmed),
            "avg_speed": round(sum(speeds) / len(speeds), 2) if speeds else 0,
            "min_speed": round(min(speeds), 2) if speeds else 0,
            "danger_count": danger_n,
            "slow_count": slow_n,
            "elderly_count": elderly_n,
            "normal_count": len(confirmed) - danger_n - slow_n,
        },
    }


@app.websocket("/ws/tracks")
async def ws_tracks(ws: WebSocket):
    await ws.accept()
    print(f"[WS] Client connected: {ws.client}")
    try:
        while True:
            with _lock_tracks:
                tracks = list(_latest_tracks)
            await ws.send_text(json.dumps(_build_payload(tracks)))
            await asyncio.sleep(1 / 25)
    except WebSocketDisconnect:
        print(f"[WS] Client disconnected: {ws.client}")
    except Exception as exc:  # noqa: BLE001
        print(f"[WS] Error: {exc}")


@app.get("/health")
def health():
    with _lock_tracks:
        track_count = len(_latest_tracks)
    return {
        "status": "ok",
        "frame_count": tracker.frame_count,
        "track_count": track_count,
        "fps": round(tracker.fps, 1),
    }


@app.get("/config")
def config():
    return {
        "source": str(raw_source),
        "pixels_per_meter": args.ppm,
        "conf_threshold": args.conf,
        "roi": tracker.roi,
        "sumo_api": args.sumo_api,
        "camera_id": args.camera_id,
        "crossing_edge": args.crossing_edge,
        "thresholds": {"normal_min": THR_NORMAL, "slow_min": THR_SLOW},
        "frame_dims": _frame_dims,
    }


if __name__ == "__main__":
    import uvicorn

    print(f"\n[Server] Starting  -> http://{args.host}:{args.port}")
    print(f"[Server] Video feed -> http://localhost:{args.port}/video_feed")
    print(f"[Server] WebSocket  -> ws://localhost:{args.port}/ws/tracks")
    print(f"[Server] SUMO API   -> {args.sumo_api}\n")
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")

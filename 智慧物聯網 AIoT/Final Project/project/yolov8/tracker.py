from __future__ import annotations

from collections import defaultdict, deque
from datetime import datetime
import csv

import cv2
import numpy as np
from deep_sort_realtime.deepsort_tracker import DeepSort
from ultralytics import YOLO


THR_NORMAL = 1.00
THR_SLOW = 0.60


class SpeedEstimator:
    def __init__(
        self,
        pixels_per_meter: float = 175.0,
        fps: float = 30.0,
        history_len: int = 16,
        ema_alpha: float = 0.30,
    ) -> None:
        self.ppm = pixels_per_meter
        self.fps = fps
        self.hl = history_len
        self.alpha = ema_alpha
        self._hist: dict[int, deque] = defaultdict(lambda: deque(maxlen=history_len))
        self._speeds: dict[int, float] = {}

    def update(self, track_id: int, cx: float, cy: float, frame_idx: int) -> float:
        self._hist[track_id].append((cx, cy, frame_idx))
        hist = self._hist[track_id]

        if len(hist) < 4:
            return self._speeds.get(track_id, 0.0)

        old_cx, old_cy, old_fi = hist[0]
        new_cx, new_cy, new_fi = hist[-1]
        frame_delta = max(1, new_fi - old_fi)

        dist_px = np.hypot(new_cx - old_cx, new_cy - old_cy)
        time_s = frame_delta / self.fps
        raw_speed = (dist_px / self.ppm) / time_s

        prev = self._speeds.get(track_id, raw_speed)
        smooth = self.alpha * raw_speed + (1 - self.alpha) * prev
        smooth = min(smooth, 2.5)

        self._speeds[track_id] = smooth
        return round(smooth, 3)

    def get(self, track_id: int) -> float:
        return round(self._speeds.get(track_id, 0.0), 3)

    def purge(self, active_ids: list[int]) -> None:
        stale = set(self._hist.keys()) - set(active_ids)
        for tid in stale:
            self._hist.pop(tid, None)
            self._speeds.pop(tid, None)


def open_source(source) -> cv2.VideoCapture:
    cap = cv2.VideoCapture(source)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video source: {source!r}")
    return cap


class PedestrianTracker:
    TRAIL_LEN = 24
    MAX_GHOST_AGE = 6

    def __init__(
        self,
        source=0,
        pixels_per_m: float = 175.0,
        conf_thresh: float = 0.40,
        deepsort_age: int = 20,
        deepsort_ninit: int = 1,
        roi=None,
        log_path: str = "speed_log.csv",
    ) -> None:
        print("[Tracker] Loading YOLOv8s model")
        self.yolo = YOLO("yolov8s.pt")
        self.roi = roi

        self.sort = DeepSort(
            max_age=deepsort_age,
            n_init=deepsort_ninit,
            nn_budget=100,
            max_cosine_distance=0.99,
        )

        self.cap = open_source(source)
        self.fps = self.cap.get(cv2.CAP_PROP_FPS) or 30.0
        self.frame_w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.frame_h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        self.frame_count = 0
        self.conf_thresh = conf_thresh

        self.speed_est = SpeedEstimator(
            pixels_per_meter=pixels_per_m,
            fps=self.fps,
        )

        self._trails: dict[int, deque] = defaultdict(lambda: deque(maxlen=self.TRAIL_LEN))
        self._last_track: dict[int, dict] = {}
        self._ghost_age: dict[int, int] = defaultdict(int)
        self._last_track_results: list[dict] = []

        self.log_path = log_path
        self._init_log()

    def _init_log(self) -> None:
        with open(self.log_path, "w", newline="") as f:
            csv.writer(f).writerow(
                [
                    "timestamp",
                    "frame",
                    "track_id",
                    "speed_ms",
                    "status",
                    "bbox_x",
                    "bbox_y",
                ]
            )

    def _log_track(self, track: dict, frame_idx: int) -> None:
        with open(self.log_path, "a", newline="") as f:
            csv.writer(f).writerow(
                [
                    datetime.now().isoformat(),
                    frame_idx,
                    track["id"],
                    track["speed"],
                    track["status"],
                    track["bbox"][0],
                    track["bbox"][1],
                ]
            )

    @staticmethod
    def _status(speed: float) -> str:
        if speed == 0.0:
            return "unknown"
        if speed >= THR_NORMAL:
            return "normal"
        if speed >= THR_SLOW:
            return "slow"
        return "danger"

    def _loop_if_file(self) -> bool:
        """Loop a file source back to the first frame when it reaches the end."""
        total = self.cap.get(cv2.CAP_PROP_FRAME_COUNT)
        if total > 0:
            pos = self.cap.get(cv2.CAP_PROP_POS_FRAMES)
            if pos >= total - 1:
                self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                return True
        return False

    def _process_ghosts(self, active_ids: list[int], track_results: list[dict]) -> None:
        for tid, last in list(self._last_track.items()):
            if tid in active_ids:
                continue

            self._ghost_age[tid] += 1
            age = self._ghost_age[tid]
            if age <= self.MAX_GHOST_AGE:
                ghost = dict(last)
                ghost["confirmed"] = False
                ghost["speed"] = round(last["speed"] * (1 - age / self.MAX_GHOST_AGE), 3)
                ghost["status"] = self._status(ghost["speed"])
                track_results.append(ghost)
            else:
                self._last_track.pop(tid, None)
                self._ghost_age.pop(tid, None)
                self._trails.pop(tid, None)


class CctvSnapshotSource:
    def __init__(self, url: str, refresh: float = 0.5):
        self.url = url
        self.refresh = refresh
        self._last = 0.0
        self._frame = None
        self.fps = 1.0 / refresh
        self.frame_w = 0
        self.frame_h = 0

    def read(self) -> np.ndarray | None:
        import time

        import requests

        now = time.time()
        if now - self._last < self.refresh:
            return self._frame

        try:
            headers = {"User-Agent": "Mozilla/5.0"}
            resp = requests.get(self.url, headers=headers, timeout=3)
            arr = np.frombuffer(resp.content, np.uint8)
            img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
            if img is not None:
                self._frame = img
                self._last = now
                self.frame_h, self.frame_w = img.shape[:2]
        except Exception as e:  # noqa: BLE001
            print(f"[CCTV] Fetch error: {e}")

        return self._frame

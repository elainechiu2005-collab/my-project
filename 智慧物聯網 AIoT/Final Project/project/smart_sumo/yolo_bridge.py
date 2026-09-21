from __future__ import annotations

import csv
import json
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


REAL_PEDESTRIAN_SOURCE_KINDS = {"official_survey", "field_count", "yolo_baseline"}
PROTECTED_SOURCE_KINDS = {"official_survey", "field_count"}


@dataclass
class YoloEvent:
    timestamp: float
    intersection_id: str
    avg_speed_mps: float
    slow_pedestrian: bool
    raw_payload: dict
    is_elderly: bool = False
    age_group: str = ""
    ttl_seconds: int = 20


def resolve_candidate_phases(payload: dict, phase_groups: list[dict]) -> list[int]:
    crossing_id = payload.get("crossing_id")
    crossing_edge = payload.get("crossing_edge")
    target_phase = payload.get("target_phase")

    if target_phase is not None:
        return [int(target_phase)]

    matching = []
    for group in phase_groups:
        if crossing_id and crossing_id in group.get("crossing_ids", []):
            matching.append(int(group["phase_index"]))
        elif crossing_edge and crossing_edge in group.get("crossing_edges", []):
            matching.append(int(group["phase_index"]))

    if matching:
        return sorted(set(matching))

    return [int(group["phase_index"]) for group in phase_groups]


class EventStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._events: list[YoloEvent] = []

    def push(self, event: YoloEvent) -> None:
        with self._lock:
            self._events.append(event)

    def pop_active(self, now_ts: float) -> list[YoloEvent]:
        with self._lock:
            active = [event for event in self._events if event.timestamp + event.ttl_seconds >= now_ts]
            self._events.clear()
        return active


class PedestrianCounter:
    def __init__(
        self,
        manual_csv_path: Path,
        generated_csv_path: Path,
        state_json_path: Path,
        intersection_id: str,
        phase_groups: list[dict],
        default_slow_share: float,
        flush_interval_seconds: int = 5,
        track_dedupe_seconds: int = 90,
    ) -> None:
        self.manual_csv_path = manual_csv_path
        self.generated_csv_path = generated_csv_path
        self.state_json_path = state_json_path
        self.intersection_id = intersection_id
        self.phase_groups = phase_groups
        self.default_slow_share = default_slow_share
        self.flush_interval_seconds = flush_interval_seconds
        self.track_dedupe_seconds = track_dedupe_seconds

        self._lock = threading.Lock()
        self._session_started_at = time.time()
        self._last_flush_at = 0.0
        self._phase_counts: dict[int, int] = {int(group["phase_index"]): 0 for group in phase_groups}
        self._phase_slow_counts: dict[int, int] = {int(group["phase_index"]): 0 for group in phase_groups}
        self._unknown_count = 0
        self._total_speed_weighted = 0.0
        self._total_count = 0
        self._recent_tracks: dict[tuple[str, str], float] = {}

    def ingest(self, event: YoloEvent) -> None:
        if event.intersection_id != self.intersection_id:
            return

        with self._lock:
            now_ts = event.timestamp
            self._cleanup_old_tracks(now_ts)

            phases = resolve_candidate_phases(event.raw_payload, self.phase_groups)
            target_phase = phases[0] if len(phases) == 1 else None
            count = self._extract_count(event, now_ts)
            if count <= 0:
                return

            if target_phase is None:
                self._unknown_count += count
            else:
                self._phase_counts[target_phase] = self._phase_counts.get(target_phase, 0) + count
                if event.slow_pedestrian:
                    self._phase_slow_counts[target_phase] = self._phase_slow_counts.get(target_phase, 0) + count

            self._total_count += count
            self._total_speed_weighted += event.avg_speed_mps * count

            if now_ts - self._last_flush_at >= self.flush_interval_seconds:
                self._flush_locked(now_ts)

    def flush(self) -> None:
        with self._lock:
            self._flush_locked(time.time())

    def _extract_count(self, event: YoloEvent, now_ts: float) -> int:
        payload = event.raw_payload
        track_ids = payload.get("track_ids") or []
        if isinstance(track_ids, str):
            track_ids = [track_ids]

        crossing_key = str(payload.get("crossing_edge") or payload.get("crossing_id") or "unknown")

        if track_ids:
            unique_new_tracks = 0
            for raw_track_id in track_ids:
                track_id = str(raw_track_id).strip()
                if not track_id:
                    continue
                dedupe_key = (crossing_key, track_id)
                last_seen = self._recent_tracks.get(dedupe_key)
                if last_seen is not None and now_ts - last_seen < self.track_dedupe_seconds:
                    continue
                self._recent_tracks[dedupe_key] = now_ts
                unique_new_tracks += 1
            if unique_new_tracks > 0:
                return unique_new_tracks
            return 0

        explicit_count = payload.get("pedestrian_count", payload.get("count", 1))
        try:
            return max(0, int(explicit_count))
        except (TypeError, ValueError):
            return 1

    def _cleanup_old_tracks(self, now_ts: float) -> None:
        expired = [
            key
            for key, last_seen in self._recent_tracks.items()
            if now_ts - last_seen >= self.track_dedupe_seconds
        ]
        for key in expired:
            self._recent_tracks.pop(key, None)

    def _flush_locked(self, now_ts: float) -> None:
        self._last_flush_at = now_ts
        snapshot = self._snapshot(now_ts)
        self.generated_csv_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_json_path.parent.mkdir(parents=True, exist_ok=True)
        self.manual_csv_path.parent.mkdir(parents=True, exist_ok=True)

        generated_row = self._snapshot_to_row(snapshot)
        self._write_csv(self.generated_csv_path, generated_row, overwrite_protected=False)
        self._write_csv(self.manual_csv_path, generated_row, overwrite_protected=False)
        self.state_json_path.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding="utf-8")

    def _snapshot(self, now_ts: float) -> dict:
        observed_seconds = max(1.0, now_ts - self._session_started_at)
        phase0_count = int(self._phase_counts.get(0, 0))
        phase5_count = int(self._phase_counts.get(5, 0))
        total_count = phase0_count + phase5_count + self._unknown_count
        total_slow = sum(self._phase_slow_counts.values())
        slow_share = (total_slow / total_count) if total_count else self.default_slow_share
        hourly_scale = 3600.0 / observed_seconds
        avg_speed = (self._total_speed_weighted / self._total_count) if self._total_count else 0.0

        return {
            "official_icid": self.intersection_id,
            "source_kind": "yolo_baseline",
            "source_note": (
                "Auto-generated from YOLO event stream; "
                f"observed_seconds={observed_seconds:.1f}; "
                f"raw_phase0={phase0_count}; raw_phase5={phase5_count}; raw_unknown={self._unknown_count}"
            ),
            "last_updated_utc": datetime.fromtimestamp(now_ts, tz=timezone.utc).isoformat(timespec="seconds"),
            "observed_seconds": round(observed_seconds, 1),
            "phase0_count": phase0_count,
            "phase5_count": phase5_count,
            "unknown_count": int(self._unknown_count),
            "phase0_group_hourly": int(round(phase0_count * hourly_scale)),
            "phase5_group_hourly": int(round(phase5_count * hourly_scale)),
            "slow_share": round(slow_share, 4),
            "avg_speed_mps": round(avg_speed, 4),
            "is_real_pedestrian_data": True,
            "is_official_pedestrian_data": False,
        }

    def _snapshot_to_row(self, snapshot: dict) -> dict[str, str]:
        return {
            "official_icid": snapshot["official_icid"],
            "phase0_group_hourly": str(snapshot["phase0_group_hourly"]),
            "phase5_group_hourly": str(snapshot["phase5_group_hourly"]),
            "slow_share": str(snapshot["slow_share"]),
            "source_kind": snapshot["source_kind"],
            "source_note": snapshot["source_note"],
            "last_updated_utc": snapshot["last_updated_utc"],
            "observed_seconds": str(snapshot["observed_seconds"]),
            "phase0_count": str(snapshot["phase0_count"]),
            "phase5_count": str(snapshot["phase5_count"]),
            "unknown_count": str(snapshot["unknown_count"]),
            "avg_speed_mps": str(snapshot["avg_speed_mps"]),
        }

    def _write_csv(self, path: Path, updated_row: dict[str, str], overwrite_protected: bool) -> None:
        rows: list[dict[str, str]] = []
        fieldnames = [
            "official_icid",
            "phase0_group_hourly",
            "phase5_group_hourly",
            "slow_share",
            "source_kind",
            "source_note",
            "last_updated_utc",
            "observed_seconds",
            "phase0_count",
            "phase5_count",
            "unknown_count",
            "avg_speed_mps",
        ]

        if path.exists():
            with path.open("r", encoding="utf-8-sig", newline="") as fh:
                reader = csv.DictReader(fh)
                if reader.fieldnames:
                    for name in reader.fieldnames:
                        if name not in fieldnames:
                            fieldnames.append(name)
                rows = list(reader)

        row_updated = False
        for index, row in enumerate(rows):
            if row.get("official_icid") != self.intersection_id:
                continue
            existing_source = (row.get("source_kind") or "").strip()
            if existing_source in PROTECTED_SOURCE_KINDS and not overwrite_protected:
                return
            merged = {name: row.get(name, "") for name in fieldnames}
            merged.update(updated_row)
            rows[index] = merged
            row_updated = True
            break

        if not row_updated:
            rows.append({name: updated_row.get(name, "") for name in fieldnames})

        with path.open("w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)


def build_server(
    host: str,
    port: int,
    route: str,
    store: EventStore,
    counter: PedestrianCounter | None = None,
) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            if self.path != route:
                self.send_response(404)
                self.end_headers()
                return

            content_length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(content_length).decode("utf-8"))
            event = YoloEvent(
                timestamp=time.time(),
                intersection_id=payload["intersection_id"],
                avg_speed_mps=float(payload["avg_speed_mps"]),
                raw_payload=payload,
                is_elderly=bool(
                    payload.get(
                        "is_elderly",
                        payload.get("elderly", str(payload.get("age_group", "")).strip().lower() == "elderly"),
                    )
                ),
                age_group=str(payload.get("age_group", "")).strip().lower(),
                slow_pedestrian=bool(
                    payload.get(
                        "slow_pedestrian",
                        float(payload["avg_speed_mps"]) < 1.0
                        or bool(
                            payload.get(
                                "is_elderly",
                                payload.get(
                                    "elderly",
                                    str(payload.get("age_group", "")).strip().lower() == "elderly",
                                ),
                            )
                        ),
                    )
                ),
                ttl_seconds=int(payload.get("ttl_seconds", 20)),
            )
            store.push(event)
            if counter is not None:
                counter.ingest(event)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            return

    return ThreadingHTTPServer((host, port), Handler)

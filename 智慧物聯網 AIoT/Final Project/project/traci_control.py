from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from datetime import datetime

from smart_sumo.config import load_settings, resolve_path
from smart_sumo.signal_calibration import select_plan_id
from smart_sumo.yolo_bridge import EventStore, PedestrianCounter, YoloEvent, build_server, resolve_candidate_phases

SUMO_HOME = os.environ.get("SUMO_HOME", r"D:\\")
os.environ.setdefault("SUMO_HOME", SUMO_HOME)
SUMO_TOOLS = os.path.join(SUMO_HOME, "tools")
if SUMO_TOOLS not in sys.path:
    sys.path.append(SUMO_TOOLS)

try:
    import traci
except ModuleNotFoundError as exc:
    raise SystemExit(
        "Could not import traci. Install SUMO or set SUMO_HOME to a SUMO installation that includes the Python tools directory."
    ) from exc


def _clock_to_segmenttype(settings: dict, weekday: int) -> int:
    if weekday == 5:
        return settings["target_tls"]["saturday_segmenttype"]
    if weekday == 6:
        return settings["target_tls"]["sunday_segmenttype"]
    return settings["target_tls"]["weekday_segmenttype"]


def _apply_signal_plan(tls_id: str, plan_id: str, calibration: dict) -> None:
    logic = traci.trafficlight.getAllProgramLogics(tls_id)[0]
    override = calibration["plan_overrides"][plan_id]
    phases = []
    if len(logic.phases) != len(override["recommended_phase_durations"]):
        raise RuntimeError(
            "Signal calibration phase count does not match the current SUMO program logic."
        )
    for original, duration in zip(logic.phases, override["recommended_phase_durations"]):
        phases.append(
            traci.trafficlight.Phase(
                duration=duration,
                state=original.state,
                minDur=duration,
                maxDur=duration,
                next=original.next,
                name=original.name,
            )
        )
    updated_logic = traci.trafficlight.Logic(
        programID=f"{logic.programID}_plan_{plan_id}",
        type=logic.type,
        currentPhaseIndex=0,
        phases=phases,
        subParameter=logic.subParameter,
    )
    traci.trafficlight.setProgramLogic(tls_id, updated_logic)


def _build_sumo_command(settings: dict, sumo_binary: str | None) -> list[str]:
    generated_dir = resolve_path(settings, settings["paths"]["generated_dir"])
    binary = sumo_binary or settings["simulation"]["sumo_binary"]
    command = [
        binary,
        "-n",
        str(resolve_path(settings, settings["network"]["net_file"])),
        "-r",
        ",".join(
            [
                str(generated_dir / "real_vehicle_flows.rou.xml"),
                str(generated_dir / "real_pedestrians.rou.xml"),
            ]
        ),
        "--begin",
        "0",
        "--end",
        str(settings["simulation"]["duration_seconds"]),
        "--step-length",
        "1.0",
        "--tripinfo-output",
        str(resolve_path(settings, settings["simulation"]["tripinfo_output"])),
        "--no-step-log",
        "true",
    ]
    if "gui" in binary:
        command.extend(["--start", "--delay", str(settings["simulation"]["gui_delay_ms"])])
        gui_settings = resolve_path(settings, settings["network"]["gui_settings_file"])
        if gui_settings.exists():
            command.extend(["-g", str(gui_settings)])
    return command


def _resolve_event_phases(event: YoloEvent, calibration: dict) -> list[int]:
    return resolve_candidate_phases(event.raw_payload, calibration.get("pedestrian_phase_groups", []))


THR_NORMAL = 1.00
THR_SLOW = 0.60


def _speed_extension(avg_speed_mps: float, ext_slow: int, ext_danger: int) -> int:
    """Return green-light extension seconds based on pedestrian speed.

    speed == 0.0          → unknown (insufficient history) → 0 s
    speed >= THR_NORMAL   → normal walking speed           → 0 s
    THR_SLOW <= speed < THR_NORMAL → slow (elderly pace)  → ext_slow s
    speed < THR_SLOW      → danger (very slow)             → ext_danger s
    """
    if avg_speed_mps == 0.0:
        return 0
    if avg_speed_mps >= THR_NORMAL:
        return 0
    if avg_speed_mps >= THR_SLOW:
        return ext_slow
    return ext_danger


def _record_event(log: list[str], log_path, message: str) -> None:
    print(message, flush=True)
    log.append(message)
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(message + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run SUMO with official Taipei timing plans, traffic data, and YOLO events.")
    parser.add_argument("--config", default="project_settings.json")
    parser.add_argument("--clock", default=None, help="Simulation wall clock in HH:MM")
    parser.add_argument("--weekday", type=int, default=0, help="Python weekday: Monday=0 ... Sunday=6")
    parser.add_argument("--sumo-binary", default=None)
    parser.add_argument("--no-yolo", action="store_true")
    args = parser.parse_args()

    settings = load_settings(args.config)
    generated_dir = resolve_path(settings, settings["paths"]["generated_dir"])
    calibration_path = generated_dir / "signal_calibration.json"
    if not calibration_path.exists():
        raise SystemExit("Run `python prepare_real_sumo.py --force-download` first.")

    calibration = json.loads(calibration_path.read_text(encoding="utf-8"))
    traffic_summary = json.loads((generated_dir / "traffic_summary.json").read_text(encoding="utf-8"))
    clock_hhmm = args.clock or settings["simulation"]["start_clock"]
    segmenttype = _clock_to_segmenttype(settings, args.weekday)
    plan_id = select_plan_id(calibration, clock_hhmm, segmenttype)

    traci.start(_build_sumo_command(settings, args.sumo_binary))
    traci.simulationStep()

    tls_id = settings["target_tls"]["sumo_tls_id"]
    _apply_signal_plan(tls_id, plan_id, calibration)

    if "gui" in (args.sumo_binary or settings["simulation"]["sumo_binary"]):
        traci.gui.setZoom("View #0", 500)
        x, y = traci.junction.getPosition(tls_id)
        traci.gui.setOffset("View #0", x, y)
        print(f"Focused GUI on {tls_id} at ({x:.1f}, {y:.1f})")

    print(f"Loaded official timing plan {plan_id} for {clock_hhmm} (segmenttype={segmenttype})")
    print(f"Pedestrian data real={traffic_summary['pedestrian_meta']['is_real_pedestrian_data']} source={traffic_summary['pedestrian_meta']['source_kind']}")

    store = EventStore()
    server = None
    counter = None
    if settings["yolo_bridge"]["enabled"] and not args.no_yolo:
        counter = PedestrianCounter(
            manual_csv_path=resolve_path(settings, settings["pedestrian_generation"]["counts_csv"]),
            generated_csv_path=resolve_path(settings, settings["yolo_bridge"]["counts_csv"]),
            state_json_path=resolve_path(settings, settings["yolo_bridge"]["state_json"]),
            intersection_id=settings["target_tls"]["official_icid"],
            phase_groups=calibration.get("pedestrian_phase_groups", []),
            default_slow_share=settings["pedestrian_generation"]["default_slow_share"],
            flush_interval_seconds=int(settings["yolo_bridge"]["flush_interval_seconds"]),
            track_dedupe_seconds=int(settings["yolo_bridge"]["track_dedupe_seconds"]),
        )
        server = build_server(
            settings["yolo_bridge"]["host"],
            settings["yolo_bridge"]["port"],
            settings["yolo_bridge"]["route"],
            store,
            counter,
        )
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(
            "YOLO bridge listening on "
            f"http://{settings['yolo_bridge']['host']}:{settings['yolo_bridge']['port']}{settings['yolo_bridge']['route']}"
        )
        print(
            "YOLO pedestrian counts will be written to "
            f"{resolve_path(settings, settings['yolo_bridge']['counts_csv'])}"
        )

    pending_events: list[dict] = []
    extended_this_phase = False
    last_phase = -1
    ext_slow = int(settings["target_tls"]["green_extension_slow_seconds"])
    ext_danger = int(settings["target_tls"]["green_extension_danger_seconds"])
    log = []
    event_log_path = resolve_path(settings, settings["yolo_bridge"]["event_log"])
    event_log_path.parent.mkdir(parents=True, exist_ok=True)
    event_log_path.write_text(
        f"Simulation started at {datetime.now().isoformat(timespec='seconds')}\n",
        encoding="utf-8",
    )

    while traci.simulation.getMinExpectedNumber() > 0:
        traci.simulationStep()
        sim_time = traci.simulation.getTime()
        current_phase = traci.trafficlight.getPhase(tls_id)

        if current_phase != last_phase:
            extended_this_phase = False
            last_phase = current_phase

        pending_events = [item for item in pending_events if item["expire_at"] >= sim_time]

        for event in store.pop_active(time.time()):
            if event.intersection_id != settings["target_tls"]["official_icid"]:
                continue
            if not (event.slow_pedestrian or event.is_elderly):
                continue
            candidate_phases = _resolve_event_phases(event, calibration)
            trigger_kind = "elderly" if event.is_elderly else "slow"
            pending_events.append(
                {
                    "expire_at": sim_time + settings["target_tls"]["pending_extension_max_age"],
                    "candidate_phases": candidate_phases,
                    "avg_speed_mps": event.avg_speed_mps,
                    "crossing_edge": event.raw_payload.get("crossing_edge", ""),
                    "crossing_id": event.raw_payload.get("crossing_id", ""),
                    "trigger_kind": trigger_kind,
                }
            )
            _record_event(
                log,
                event_log_path,
                f"[{sim_time:6.1f}s] queued {trigger_kind}-pedestrian event speed={event.avg_speed_mps:.2f}m/s phases={candidate_phases}"
            )

        ready_event = next(
            (item for item in pending_events if current_phase in item["candidate_phases"]),
            None,
        )
        if ready_event and not extended_this_phase:
            pending_events.remove(ready_event)
            extension_seconds = _speed_extension(ready_event["avg_speed_mps"], ext_slow, ext_danger)
            trigger_kind = ready_event.get("trigger_kind", "slow")
            if extension_seconds > 0:
                remaining = traci.trafficlight.getNextSwitch(tls_id) - sim_time
                traci.trafficlight.setPhaseDuration(tls_id, remaining + extension_seconds)
                extended_this_phase = True
                _record_event(
                    log,
                    event_log_path,
                    f"[{sim_time:6.1f}s] extended phase {current_phase} by {extension_seconds}s for {trigger_kind}-pedestrian"
                    f" speed={ready_event['avg_speed_mps']:.2f}m/s crossing_edge={ready_event['crossing_edge'] or 'unspecified'} remaining_before={remaining:.1f}s"
                )
            else:
                _record_event(
                    log,
                    event_log_path,
                    f"[{sim_time:6.1f}s] no extension for {trigger_kind}-pedestrian"
                    f" speed={ready_event['avg_speed_mps']:.2f}m/s (normal or unknown) crossing_edge={ready_event['crossing_edge'] or 'unspecified'}"
                )

    traci.close(False)
    if server is not None:
        server.shutdown()
    if counter is not None:
        counter.flush()

    print("=" * 60)
    print(f"Simulation finished at {datetime.now().isoformat(timespec='seconds')}")
    print(f"Applied plan {plan_id} with {len(log)} noteworthy events")
    for entry in log:
        print(entry)


if __name__ == "__main__":
    main()

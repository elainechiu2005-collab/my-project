from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import xml.etree.ElementTree as ET

from .config import ensure_dir, resolve_path
from .network_tools import pedestrian_phase_groups


@dataclass
class CurrentLogic:
    program_id: str
    phases: list[dict]


def load_json(path: str | Path) -> list[dict]:
    with Path(path).open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _find_first_key(row: dict, required_terms: tuple[str, ...]) -> str:
    for key in row.keys():
        lowered = key.lower()
        if all(term.lower() in lowered for term in required_terms):
            return key
    raise KeyError(f"Unable to find key containing {required_terms!r} in {list(row.keys())}")


def extract_current_logic(net_file: str | Path, tls_id: str) -> CurrentLogic:
    root = ET.parse(net_file).getroot()
    for logic in root.iter("tlLogic"):
        if logic.attrib.get("id") != tls_id:
            continue
        phases = [phase.attrib.copy() for phase in logic.findall("phase")]
        return CurrentLogic(program_id=logic.attrib.get("programID", "0"), phases=phases)
    raise RuntimeError(f"Unable to find tlLogic {tls_id}")


def _recommended_phase_durations(current_logic: CurrentLogic, cycle_time: int) -> list[int]:
    green_indices = []
    clearance_total = 0
    for idx, phase in enumerate(current_logic.phases):
        state = phase["state"]
        duration = int(float(phase["duration"]))
        if "G" in state or "g" in state:
            green_indices.append(idx)
        else:
            clearance_total += duration

    available = max(cycle_time - clearance_total, len(green_indices))
    current_green_total = sum(int(float(current_logic.phases[idx]["duration"])) for idx in green_indices) or len(green_indices)

    recommended = [int(float(phase["duration"])) for phase in current_logic.phases]
    assigned = 0
    for idx in green_indices:
        original = int(float(current_logic.phases[idx]["duration"]))
        scaled = max(1, round(original / current_green_total * available))
        recommended[idx] = scaled
        assigned += scaled

    diff = available - assigned
    if green_indices:
        recommended[green_indices[-1]] += diff
    return recommended


def build_signal_calibration(settings: dict, raw_files: dict[str, Path]) -> Path:
    target = settings["target_tls"]
    current_logic = extract_current_logic(resolve_path(settings, settings["network"]["net_file"]), target["sumo_tls_id"])
    timing_plans = load_json(raw_files["timing_plan"])
    schedules = load_json(raw_files["timing_schedule"])

    intersection_plans = [row for row in timing_plans if row.get("icid") == target["official_icid"]]
    if not intersection_plans:
        raise RuntimeError(f"No timing plans found for {target['official_icid']}")

    intersection_schedules = [row for row in schedules if row.get("icid") == target["official_icid"]]
    if not intersection_schedules:
        raise RuntimeError(f"No timing schedules found for {target['official_icid']}")

    plan_id_key = _find_first_key(intersection_plans[0], ("planid", "seq"))

    overrides = {}
    for row in intersection_plans:
        plan_id = str(row[plan_id_key])
        overrides[plan_id] = {
            "plan_id": plan_id,
            "cycle_time": int(row["cycletime"]),
            "offset": int(row["offset"]),
            "phaseorder": row["phaseorder"],
            "direction": int(row["direction"]),
            "subplan": row["subplan"],
            "recommended_phase_durations": _recommended_phase_durations(current_logic, int(row["cycletime"])),
        }

    cleaned_schedules = []
    for schedule in intersection_schedules:
        subsegment_plan_key = _find_first_key(schedule["subsegment"][0], ("planid", "seq"))
        cleaned_schedules.append(
            {
                "segmenttype": int(schedule["segmenttype"]),
                "subsegment": [
                    {
                        "subsegment_id": int(item["subsegmentid"]),
                        "time": item["time"],
                        "plan_id": str(item[subsegment_plan_key]),
                    }
                    for item in schedule["subsegment"]
                ],
            }
        )

    phase_groups = [
        {
            "phase_index": group.phase_index,
            "crossing_ids": group.crossing_ids,
            "crossing_edges": group.crossing_edges,
        }
        for group in pedestrian_phase_groups(resolve_path(settings, settings["network"]["net_file"]), target["sumo_tls_id"])
    ]

    payload = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "official_icid": target["official_icid"],
        "official_name": target["official_name"],
        "tls_id": target["sumo_tls_id"],
        "base_logic": current_logic.phases,
        "segment_schedules": cleaned_schedules,
        "plan_overrides": overrides,
        "pedestrian_phase_groups": phase_groups,
        "notes": [
            "recommended_phase_durations preserves the current SUMO phase states and rescales the cycle to the official Taipei timing plan.",
            "pedestrian_phase_groups are derived from SUMO linkIndex mappings and identify which pedestrian crossings are green in each phase.",
        ],
    }

    generated_dir = ensure_dir(resolve_path(settings, settings["paths"]["generated_dir"]))
    output = generated_dir / "signal_calibration.json"
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return output


def select_plan_id(calibration: dict, clock_hhmm: str, segmenttype: int) -> str:
    schedule = next(
        (item for item in calibration["segment_schedules"] if int(item["segmenttype"]) == int(segmenttype)),
        None,
    )
    if schedule is None:
        return sorted(calibration["plan_overrides"].keys())[0]

    active = str(schedule["subsegment"][0]["plan_id"])
    for row in schedule["subsegment"]:
        if row["time"] <= clock_hhmm.replace(":", ""):
            active = str(row["plan_id"])
        else:
            break
    return active

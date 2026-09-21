from __future__ import annotations

import csv
import io
import json
from collections import defaultdict
from pathlib import Path
import xml.etree.ElementTree as ET

from .config import ensure_dir, resolve_path
from .network_tools import distance_m, find_target_incoming_edges, normalize_road_name, turn_distribution
from .yolo_bridge import REAL_PEDESTRIAN_SOURCE_KINDS


def _load_signal_positions(path: str | Path) -> list[dict]:
    text = Path(path).read_bytes().decode("cp950")
    return list(csv.DictReader(io.StringIO(text), delimiter="\t"))


def _load_sections(path: str | Path) -> list[dict]:
    root = ET.parse(path).getroot()
    ns = {"vd": "http://www.iii.org.tw/dax/vd"}
    rows = []
    for section in root.findall(".//vd:SectionData", ns):
        row = {child.tag.split("}")[-1]: child.text for child in section}
        rows.append(row)
    return rows


def _road_name_from_section(section_name: str) -> str:
    return normalize_road_name(section_name.split("-", 1)[0].strip())


def _section_endpoint_distance(section: dict, center_lat: float, center_lon: float) -> tuple[float, float]:
    start = distance_m(float(section["StartWgsY"]), float(section["StartWgsX"]), center_lat, center_lon)
    end = distance_m(float(section["EndWgsY"]), float(section["EndWgsX"]), center_lat, center_lon)
    return start, end


def _measured_inbound_volumes(settings: dict, raw_files: dict[str, Path]) -> dict[str, float]:
    center = settings["study_area"]["center"]
    radius_m = settings["study_area"]["radius_m"]
    incoming_edges = find_target_incoming_edges(
        resolve_path(settings, settings["network"]["net_file"]),
        resolve_path(settings, settings["network"]["osm_file"]),
        settings["target_tls"]["sumo_tls_id"],
    )
    sections = _load_sections(raw_files["vd_sections"])

    measured: dict[str, float] = {}
    corridor_proxy: defaultdict[str, list[float]] = defaultdict(list)
    for section in sections:
        road_name = _road_name_from_section(section["SectionName"])
        total_vol = float(section["TotalVol"])
        start_d, end_d = _section_endpoint_distance(section, center["lat"], center["lon"])
        if min(start_d, end_d) > radius_m:
            continue

        corridor_proxy[road_name].append(total_vol)

        if end_d <= radius_m:
            best_edge_id = None
            best_dist = 1e9
            for edge in incoming_edges:
                if normalize_road_name(edge.road_name) != road_name:
                    continue
                edge_dist = distance_m(edge.end_lat, edge.end_lon, float(section["EndWgsY"]), float(section["EndWgsX"]))
                if edge_dist < best_dist:
                    best_dist = edge_dist
                    best_edge_id = edge.edge_id

            if best_edge_id and best_dist < 120:
                measured[best_edge_id] = total_vol

    if settings["traffic_generation"]["proxy_missing_edge_volume"]:
        for edge in incoming_edges:
            if edge.edge_id in measured:
                continue
            proxy_values = corridor_proxy.get(normalize_road_name(edge.road_name), [])
            if proxy_values:
                measured[edge.edge_id] = sum(proxy_values) / len(proxy_values)

    min_flow = float(settings["traffic_generation"]["minimum_flow_per_hour"]) / 12.0
    for edge in incoming_edges:
        measured.setdefault(edge.edge_id, min_flow)

    return measured


def _load_csv_lookup(path: Path) -> dict[str, dict]:
    if not path.exists():
        return {}

    lookup = {}
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        for row in csv.DictReader(fh):
            lookup[row["official_icid"]] = row
    return lookup


def _build_manual_pedestrian_lookup(settings: dict) -> dict[str, dict]:
    manual_path = resolve_path(settings, settings["pedestrian_generation"]["counts_csv"])
    generated_path = resolve_path(settings, settings["yolo_bridge"]["counts_csv"])

    lookup = _load_csv_lookup(manual_path)
    generated_lookup = _load_csv_lookup(generated_path)
    for official_icid, row in generated_lookup.items():
        existing = lookup.get(official_icid, {})
        if existing.get("source_kind") in {"official_survey", "field_count"}:
            continue
        lookup[official_icid] = row

    return lookup


def build_vehicle_routes(settings: dict, raw_files: dict[str, Path]) -> Path:
    generated_dir = ensure_dir(resolve_path(settings, settings["paths"]["generated_dir"]))
    output = generated_dir / "real_vehicle_flows.rou.xml"
    volumes = _measured_inbound_volumes(settings, raw_files)
    distributions = turn_distribution(
        resolve_path(settings, settings["network"]["net_file"]),
        settings["target_tls"]["sumo_tls_id"],
        settings["traffic_generation"]["turn_ratio"],
    )
    class_split = settings["traffic_generation"]["vehicle_class_split"]
    duration = settings["simulation"]["duration_seconds"]

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<routes xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://sumo.dlr.de/xsd/routes_file.xsd">',
        '    <vType id="passenger" accel="2.6" decel="4.5" sigma="0.5" length="5.0" maxSpeed="13.9" guiShape="passenger"/>',
        '    <vType id="bus" accel="1.2" decel="4.0" sigma="0.5" length="12.0" maxSpeed="12.5" guiShape="bus"/>',
        '    <vType id="truck" accel="1.1" decel="4.0" sigma="0.5" length="8.0" maxSpeed="11.1" guiShape="truck"/>',
    ]

    for incoming_id, flow_5min in sorted(volumes.items()):
        total_vehicles = max(1, round(flow_5min * duration / 300.0))
        targets = distributions[incoming_id]
        for vehicle_type, share in class_split.items():
            vehicle_count = max(0, round(total_vehicles * share))
            if vehicle_count == 0:
                continue
            assigned = 0
            for index, (target_edge, probability) in enumerate(targets):
                per_route = round(vehicle_count * probability)
                if index == len(targets) - 1:
                    per_route = vehicle_count - assigned
                assigned += per_route
                if per_route <= 0:
                    continue
                flow_id = f"{vehicle_type}_{incoming_id.replace('#', '_').replace('-', 'neg_')}_{index}"
                lines.append(
                    f'    <flow id="{flow_id}" type="{vehicle_type}" begin="0" end="{duration}" number="{per_route}" departLane="best" departSpeed="max">'
                )
                lines.append(f'        <route edges="{incoming_id} {target_edge}"/>')
                lines.append("    </flow>")

    lines.append("</routes>")
    output.write_text("\n".join(lines), encoding="utf-8")
    return output


def build_pedestrian_routes(settings: dict, raw_files: dict[str, Path]) -> tuple[Path, dict]:
    generated_dir = ensure_dir(resolve_path(settings, settings["paths"]["generated_dir"]))
    output = generated_dir / "real_pedestrians.rou.xml"
    signal_rows = _load_signal_positions(raw_files["signal_positions"])

    target_row = next(
        (row for row in signal_rows if row["地點"] == settings["target_tls"]["official_name"]),
        None,
    )
    if target_row is None:
        raise RuntimeError("Unable to locate the project intersection in the official signal position file")

    manual_lookup = _build_manual_pedestrian_lookup(settings)
    row = manual_lookup.get(settings["target_tls"]["official_icid"], {})

    def parse_int(value: str | None) -> int | None:
        if value is None:
            return None
        value = value.strip()
        if not value:
            return None
        return int(float(value))

    phase0_hourly = parse_int(row.get("phase0_group_hourly"))
    phase5_hourly = parse_int(row.get("phase5_group_hourly"))
    slow_share_raw = row.get("slow_share")
    slow_share = float(slow_share_raw) if slow_share_raw not in (None, "") else settings["pedestrian_generation"]["default_slow_share"]
    source_kind = row.get("source_kind", "manual_required")
    source_note = row.get("source_note", "")

    if settings["pedestrian_generation"]["strict_real_counts"] and (phase0_hourly is None or phase5_hourly is None):
        raise RuntimeError("Pedestrian counts are missing while strict_real_counts is enabled")

    phase0_hourly = phase0_hourly or 0
    phase5_hourly = phase5_hourly or 0

    phase0_fast = round(phase0_hourly * (1.0 - slow_share))
    phase0_slow = phase0_hourly - phase0_fast
    phase5_fast = round(phase5_hourly * (1.0 - slow_share))
    phase5_slow = phase5_hourly - phase5_fast

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<routes xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://sumo.dlr.de/xsd/routes_file.xsd">',
        '    <vType id="ped_adult" vClass="pedestrian" speedFactor="1.0" speedDev="0.1"/>',
        '    <vType id="ped_slow" vClass="pedestrian" speedFactor="0.67" speedDev="0.05"/>',
        f'    <personFlow id="ped_phase0_adult" type="ped_adult" begin="0" end="{settings["simulation"]["duration_seconds"]}" number="{phase0_fast}">',
        '        <walk from="506316041#3" to="196961202#0"/>',
        "    </personFlow>",
        f'    <personFlow id="ped_phase0_slow" type="ped_slow" begin="0" end="{settings["simulation"]["duration_seconds"]}" number="{phase0_slow}">',
        '        <walk from="405980657#1" to="198922264#0"/>',
        "    </personFlow>",
        f'    <personFlow id="ped_phase5_adult" type="ped_adult" begin="0" end="{settings["simulation"]["duration_seconds"]}" number="{phase5_fast}">',
        '        <walk from="623877960#1" to="623877957#0"/>',
        "    </personFlow>",
        f'    <personFlow id="ped_phase5_slow" type="ped_slow" begin="0" end="{settings["simulation"]["duration_seconds"]}" number="{phase5_slow}">',
        '        <walk from="623877960#1" to="623877957#0"/>',
        "    </personFlow>",
        "</routes>",
    ]
    output.write_text("\n".join(lines), encoding="utf-8")

    metadata = {
        "source_kind": source_kind,
        "source_note": source_note,
        "signal_position_lon": float(target_row["WGS經度座標"]),
        "signal_position_lat": float(target_row["WGS緯度座標"]),
        "phase0_group_hourly": phase0_hourly,
        "phase5_group_hourly": phase5_hourly,
        "slow_share": slow_share,
        "is_real_pedestrian_data": source_kind in REAL_PEDESTRIAN_SOURCE_KINDS,
        "is_official_pedestrian_data": source_kind == "official_survey",
    }
    return output, metadata


def build_all_routes(settings: dict, raw_files: dict[str, Path]) -> dict[str, Path]:
    vehicle_path = build_vehicle_routes(settings, raw_files)
    pedestrian_path, pedestrian_meta = build_pedestrian_routes(settings, raw_files)
    metadata_path = ensure_dir(resolve_path(settings, settings["paths"]["generated_dir"])) / "traffic_summary.json"
    metadata = {
        "vehicle_routes": str(vehicle_path),
        "pedestrian_routes": str(pedestrian_path),
        "pedestrian_meta": pedestrian_meta,
        "notes": [
            "Vehicle flows are derived from nearby official Taipei VD section volumes.",
            "Pedestrian flows are considered measured when source_kind is official_survey, field_count, or yolo_baseline.",
            "Only official_survey should be described as government official pedestrian data.",
        ],
    }
    metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    return {
        "vehicle_routes": vehicle_path,
        "pedestrian_routes": pedestrian_path,
        "traffic_summary": metadata_path,
    }

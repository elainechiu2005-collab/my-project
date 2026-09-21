from __future__ import annotations

import math
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

import sumolib


def distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    lat_scale = 111_000.0
    lon_scale = 101_000.0
    dx = (lon2 - lon1) * lon_scale
    dy = (lat2 - lat1) * lat_scale
    return math.hypot(dx, dy)


def normalize_road_name(name: str) -> str:
    return "".join(name.split()).replace("路", "")


def base_way_id(edge_id: str) -> str:
    value = edge_id.lstrip("-")
    return value.split("#", 1)[0]


def load_osm_metadata(osm_path: str | Path) -> tuple[dict[str, str], dict[str, list[tuple[float, float]]]]:
    root = ET.parse(osm_path).getroot()
    node_coords = {
        node.attrib["id"]: (float(node.attrib["lat"]), float(node.attrib["lon"]))
        for node in root.findall("node")
    }

    names: dict[str, str] = {}
    shapes: dict[str, list[tuple[float, float]]] = {}
    for way in root.findall("way"):
        tags = {tag.attrib["k"]: tag.attrib["v"] for tag in way.findall("tag")}
        if "name" in tags:
            names[way.attrib["id"]] = tags["name"]
        refs = [nd.attrib["ref"] for nd in way.findall("nd")]
        shapes[way.attrib["id"]] = [node_coords[ref] for ref in refs if ref in node_coords]
    return names, shapes


@dataclass
class EdgeDescriptor:
    edge_id: str
    road_name: str
    start_lat: float
    start_lon: float
    end_lat: float
    end_lon: float


@dataclass
class PedestrianPhaseGroup:
    phase_index: int
    crossing_ids: list[str]
    crossing_edges: list[str]


def build_edge_catalog(net_file: str | Path, osm_file: str | Path) -> dict[str, EdgeDescriptor]:
    net = sumolib.net.readNet(str(net_file))
    osm_names, osm_shapes = load_osm_metadata(osm_file)
    catalog: dict[str, EdgeDescriptor] = {}

    for edge in net.getEdges():
        edge_id = edge.getID()
        if edge_id.startswith(":"):
            continue

        way_id = base_way_id(edge_id)
        road_name = osm_names.get(way_id, "")
        shape = osm_shapes.get(way_id, [])
        if len(shape) < 2:
            continue

        if edge_id.startswith("-"):
            shape = list(reversed(shape))

        catalog[edge_id] = EdgeDescriptor(
            edge_id=edge_id,
            road_name=road_name,
            start_lat=shape[0][0],
            start_lon=shape[0][1],
            end_lat=shape[-1][0],
            end_lon=shape[-1][1],
        )

    return catalog


def find_target_incoming_edges(net_file: str | Path, osm_file: str | Path, tls_id: str) -> list[EdgeDescriptor]:
    net = sumolib.net.readNet(str(net_file))
    catalog = build_edge_catalog(net_file, osm_file)
    node = net.getNode(tls_id)
    return [catalog[edge.getID()] for edge in node.getIncoming() if edge.getID() in catalog]


def turn_distribution(net_file: str | Path, tls_id: str, turn_ratio: dict[str, float]) -> dict[str, list[tuple[str, float]]]:
    net = sumolib.net.readNet(str(net_file))
    node = net.getNode(tls_id)

    incoming_edges = [edge for edge in node.getIncoming() if not edge.getID().startswith(":")]
    outgoing_edges = [edge for edge in node.getOutgoing() if not edge.getID().startswith(":")]

    distribution: dict[str, list[tuple[str, float]]] = {}
    for incoming in incoming_edges:
        entries = []
        in_shape = incoming.getShape()
        in_vec = (
            in_shape[-1][0] - in_shape[-2][0],
            in_shape[-1][1] - in_shape[-2][1],
        )
        for outgoing in outgoing_edges:
            out_shape = outgoing.getShape()
            out_vec = (
                out_shape[1][0] - out_shape[0][0],
                out_shape[1][1] - out_shape[0][1],
            )
            angle = math.degrees(
                math.atan2(
                    in_vec[0] * out_vec[1] - in_vec[1] * out_vec[0],
                    in_vec[0] * out_vec[0] + in_vec[1] * out_vec[1],
                )
            )
            if abs(angle) < 35:
                weight = turn_ratio["through"]
            elif angle > 0:
                weight = turn_ratio["left"]
            else:
                weight = turn_ratio["right"]
            entries.append((outgoing.getID(), weight))

        total = sum(weight for _, weight in entries) or 1.0
        distribution[incoming.getID()] = [(edge_id, weight / total) for edge_id, weight in entries]

    return distribution


def pedestrian_phase_groups(net_file: str | Path, tls_id: str) -> list[PedestrianPhaseGroup]:
    root = ET.parse(net_file).getroot()

    crossing_edge_map = {}
    for edge in root.findall("edge"):
        edge_id = edge.attrib.get("id", "")
        if edge_id.startswith(f":{tls_id}_c"):
            crossing_edge_map[edge_id] = edge.attrib.get("crossingEdges", "")

    ped_links: dict[int, tuple[str, str]] = {}
    phase_states: list[str] = []

    for connection in root.findall("connection"):
        if connection.attrib.get("tl") != tls_id:
            continue
        link_index = int(connection.attrib["linkIndex"])
        from_edge = connection.attrib.get("from", "")
        to_edge = connection.attrib.get("to", "")
        if from_edge.startswith(f":{tls_id}_w") and to_edge.startswith(f":{tls_id}_c"):
            ped_links[link_index] = (to_edge, crossing_edge_map.get(to_edge, ""))

    for logic in root.iter("tlLogic"):
        if logic.attrib.get("id") == tls_id:
            phase_states = [phase.attrib["state"] for phase in logic.findall("phase")]
            break

    groups: list[PedestrianPhaseGroup] = []
    for phase_index, state in enumerate(phase_states):
        crossing_ids = []
        crossing_edges = []
        for link_index, (crossing_id, crossing_edge) in ped_links.items():
            if link_index < len(state) and state[link_index] in {"G", "g"}:
                crossing_ids.append(crossing_id)
                crossing_edges.append(crossing_edge)
        if crossing_ids:
            groups.append(
                PedestrianPhaseGroup(
                    phase_index=phase_index,
                    crossing_ids=crossing_ids,
                    crossing_edges=crossing_edges,
                )
            )
    return groups

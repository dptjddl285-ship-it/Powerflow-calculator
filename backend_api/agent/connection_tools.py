"""Connection Verification Adapter Tools for VisionFlow Agent Connection Verifier."""
from __future__ import annotations

from typing import Any, Dict, List, Mapping, Sequence
import numpy as np

from core.pipeline_policy import GraphIssue, validate_graph


def validate_topology_graph(
    nodes: Sequence[Mapping[str, Any]],
    lines: Sequence[Mapping[str, Any]],
) -> List[Dict[str, Any]]:
    """Run deterministic graph validation on current nodes and lines."""
    issues = validate_graph(nodes, lines)
    return [issue.to_dict() for issue in issues]


def inspect_node_ports(node: Mapping[str, Any]) -> List[str]:
    """Inspect available electrical attachment port candidates for a node."""
    class_name = str(node.get("class", "")).lower()
    if class_name == "bus":
        return ["top", "bottom", "left", "right", "center_top", "center_bottom"]
    elif class_name == "transformer":
        return ["port_primary", "port_secondary", "port_top", "port_bottom"]
    elif class_name in ("generator", "load"):
        return ["lead_port", "top", "bottom", "left", "right"]
    return ["auto", "center"]


def find_candidate_target_buses(
    source_node_id: str,
    nodes: Sequence[Mapping[str, Any]],
    lines: Sequence[Mapping[str, Any]],
) -> List[Dict[str, Any]]:
    """Find nearby candidate buses for a component requiring connection."""
    source_node = next((n for n in nodes if str(n.get("id")) == source_node_id), None)
    if not source_node:
        return []

    src_bbox = source_node.get("bbox", [0.0, 0.0, 10.0, 10.0])
    src_cx, src_cy = float(src_bbox[0]), float(src_bbox[1])

    buses = [n for n in nodes if str(n.get("class", "")).lower() == "bus" and str(n.get("id")) != source_node_id]
    candidates = []

    for bus in buses:
        bus_id = str(bus.get("id"))
        bus_bbox = bus.get("bbox", [0.0, 0.0, 10.0, 10.0])
        bus_cx, bus_cy = float(bus_bbox[0]), float(bus_bbox[1])
        dist = ((src_cx - bus_cx) ** 2 + (src_cy - bus_cy) ** 2) ** 0.5

        candidates.append({
            "bus_id": bus_id,
            "distance": round(dist, 1),
            "bus_bbox": bus_bbox,
        })

    candidates.sort(key=lambda x: x["distance"])
    return candidates[:5]


def reanalyze_line_endpoint(
    image: np.ndarray,
    line: Mapping[str, Any],
    node: Mapping[str, Any],
) -> Dict[str, Any]:
    """Inspect the endpoint region between a line and an attached component."""
    if image is None or image.size == 0:
        return {"connected": True, "score": 1.0, "reason": "No image available"}

    raw_path = line.get("path", [])
    if len(raw_path) < 2:
        return {"connected": False, "score": 0.0, "reason": "Line path too short"}

    # Check proximity between path endpoint and node bounding box
    bbox = node.get("bbox", [0.0, 0.0, 10.0, 10.0])
    cx, cy, w, h = float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3])

    pt_start = raw_path[0]
    pt_end = raw_path[-1]

    d_start = ((pt_start[0] - cx) ** 2 + (pt_start[1] - cy) ** 2) ** 0.5
    d_end = ((pt_end[0] - cx) ** 2 + (pt_end[1] - cy) ** 2) ** 0.5
    min_dist = min(d_start, d_end)
    margin = max(w, h) / 2.0 + 20.0

    is_connected = min_dist <= margin
    return {
        "connected": bool(is_connected),
        "endpoint_distance": round(min_dist, 1),
        "margin": round(margin, 1),
        "score": 0.95 if is_connected else 0.40,
    }

"""Display Label Generator and Lightweight Bus Number Matcher for VisionFlow SLD Objects and Lines."""
from __future__ import annotations

import re
from typing import Any, Dict, List, Optional
import numpy as np


def extract_nearby_number(
    bbox: List[float],
    image: Optional[np.ndarray] = None,
    existing_text_candidates: Optional[List[Dict[str, Any]]] = None,
) -> Optional[int]:
    """Attempt to find a nearby bus number from image ROI or existing text candidates.

    Uses lightweight heuristics (search window around bus bbox) to find digits 1-99.
    """
    if existing_text_candidates:
        cx, cy, w, h = bbox[0], bbox[1], bbox[2], bbox[3]
        search_radius = max(w, h) * 1.5 + 40.0
        best_cand = None
        min_dist = float("inf")

        for cand in existing_text_candidates:
            text = str(cand.get("text", "")).strip()
            num_match = re.search(r"\b(\d{1,3})\b", text)
            if not num_match:
                continue

            tcx = float(cand.get("cx", 0.0))
            tcy = float(cand.get("cy", 0.0))
            dist = ((cx - tcx) ** 2 + (cy - tcy) ** 2) ** 0.5

            if dist < search_radius and dist < min_dist:
                min_dist = dist
                best_cand = int(num_match.group(1))

        if best_cand is not None:
            return best_cand

    return None


def generate_display_labels(
    nodes: List[Dict[str, Any]],
    image: Optional[np.ndarray] = None,
    existing_text_candidates: Optional[List[Dict[str, Any]]] = None,
) -> List[Dict[str, Any]]:
    """Assign human-friendly display labels and numbering to each node.

    Examples:
    - Bus: "BUS 1", "BUS 2", "BUS 4" (matched with nearby text if available)
    - Generator: "GEN 1", "GEN 2"
    - Load: "LOAD 1", "LOAD 2"
    - Transformer: "TRANS 1", "TRANS 2"
    """
    class_counters: Dict[str, int] = {
        "bus": 0,
        "generator": 0,
        "load": 0,
        "transformer": 0,
    }

    # Track used bus numbers to prevent accidental duplicates
    used_bus_numbers: set = set()
    annotated: List[Dict[str, Any]] = []

    # 1. Sort nodes spatially (top-to-bottom, left-to-right) for natural reading order
    sorted_nodes = sorted(
        nodes,
        key=lambda n: (
            float(n.get("bbox", [0, 0, 0, 0])[1]) // 50,  # group by vertical row
            float(n.get("bbox", [0, 0, 0, 0])[0]),        # sort by horizontal x
        ),
    )

    # First pass: try to detect actual bus numbers
    bus_matches: Dict[str, int] = {}
    for node in sorted_nodes:
        cls_name = str(node.get("class", node.get("class_name", "unknown"))).lower()
        node_id = str(node.get("id", ""))
        bbox = [float(v) for v in node.get("bbox", [0, 0, 10, 10])]

        if cls_name == "bus":
            detected_num = extract_nearby_number(bbox, image, existing_text_candidates)
            if detected_num is not None and detected_num not in used_bus_numbers:
                bus_matches[node_id] = detected_num
                used_bus_numbers.add(detected_num)

    # Second pass: assign display labels preserving real verified bus numbers
    for node in sorted_nodes:
        node_copy = dict(node)
        cls_name = str(node.get("class", node.get("class_name", "unknown"))).lower()
        node_id = str(node.get("id", ""))
        existing_bus_num = node.get("bus_number") or node.get("connected_bus_number")

        if cls_name == "bus":
            if existing_bus_num is not None:
                node_copy["display_label"] = f"Bus {existing_bus_num}"
                node_copy["display_number"] = existing_bus_num
                node_copy["suggested_bus_number"] = existing_bus_num
                node_copy["number_source"] = "vision_ai_grounded"
            elif node_id in bus_matches:
                bus_num = bus_matches[node_id]
                node_copy["display_label"] = f"Bus {bus_num}"
                node_copy["display_number"] = bus_num
                node_copy["suggested_bus_number"] = bus_num
                node_copy["number_source"] = "detected_text"
            else:
                node_copy["display_label"] = "Bus (미지정)"
                node_copy["display_number"] = None
                node_copy["suggested_bus_number"] = None
                node_copy["number_source"] = "unassigned"

        elif cls_name == "generator":
            if existing_bus_num is not None:
                node_copy["display_label"] = f"G_{existing_bus_num}"
                node_copy["display_number"] = existing_bus_num
            else:
                class_counters["generator"] += 1
                num = class_counters["generator"]
                node_copy["display_label"] = f"GEN {num}"
                node_copy["display_number"] = num
            node_copy["number_source"] = "device_mapping"

        elif cls_name == "load":
            if existing_bus_num is not None:
                node_copy["display_label"] = f"Load_{existing_bus_num}"
                node_copy["display_number"] = existing_bus_num
            else:
                class_counters["load"] += 1
                num = class_counters["load"]
                node_copy["display_label"] = f"LOAD {num}"
                node_copy["display_number"] = num
            node_copy["number_source"] = "device_mapping"

        elif cls_name == "transformer":
            class_counters["transformer"] += 1
            num = class_counters["transformer"]
            node_copy["display_label"] = f"TRANS {num}"
            node_copy["display_number"] = num
            node_copy["number_source"] = "sequence_fallback"

        else:
            node_copy["display_label"] = node_id.upper()
            node_copy["display_number"] = 0
            node_copy["number_source"] = "id_fallback"

        annotated.append(node_copy)

    # Restore original ID order for downstream consistency
    node_id_to_annotated = {str(n.get("id", "")): n for n in annotated}
    return [node_id_to_annotated.get(str(n.get("id", "")), n) for n in nodes]


def generate_line_display_labels(
    lines: List[Dict[str, Any]],
    nodes: Optional[List[Dict[str, Any]]] = None,
) -> List[Dict[str, Any]]:
    """Assign human-friendly display labels and endpoint names to connection lines.

    Examples:
    - display_label: "L1", "L2", "L3"
    - display_name: "L1 (BUS 1 ↔ BUS 2)"
    - endpoints_display: "BUS 1 ↔ BUS 2"
    """
    node_labels: Dict[str, str] = {}
    if nodes:
        for n in nodes:
            nid = str(n.get("id", ""))
            disp = n.get("display_label", nid)
            node_labels[nid] = disp

    annotated: List[Dict[str, Any]] = []
    for idx, line in enumerate(lines):
        line_copy = dict(line)
        line_num = idx + 1
        disp_label = f"L{line_num}"

        conn = line.get("connected_to", [])
        if len(conn) >= 2:
            from_label = node_labels.get(conn[0], conn[0])
            to_label = node_labels.get(conn[1], conn[1])
            endpoints_str = f"{from_label} ↔ {to_label}"
        elif len(conn) == 1:
            from_label = node_labels.get(conn[0], conn[0])
            endpoints_str = f"{from_label} ➔ (미연결)"
        else:
            endpoints_str = "(미연결 선로)"

        line_copy["display_label"] = disp_label
        line_copy["endpoints_display"] = endpoints_str
        line_copy["display_name"] = f"{disp_label} ({endpoints_str})"

        annotated.append(line_copy)

    return annotated

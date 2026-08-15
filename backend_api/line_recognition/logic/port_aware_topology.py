"""Port-aware, skeleton-based single-line-diagram topology extraction.

This module deliberately contains *only* line recognition.  Symbol detection
is supplied by the caller as ``components`` so it can be used with a YOLO
detector, the OpenCV detectors, or a manually corrected editor result.

Expected component schema::

    {
        "id": "bus_1",
        "class": "bus",            # bus | generator | load | transformer
        "bbox": [center_x, center_y, width, height],
    }

For directional loads, pass the arrow-tail geometry in ``load_ports``::

    {
        "load_4": {
            "point": [x, y],                 # tail / shaft-side pixel
            "direction": [dx, dy],           # tail -> arrow-head vector
            "attached_bus_id": "bus_1",     # optional CV-validated fallback
        }
    }

The returned line records retain their actual skeleton pixel paths and the
source/target ports.  This avoids the old nearest-box rule that could turn a
line toward a nearby label, load arrowhead, or transformer side.
"""

from __future__ import annotations

from collections import deque
import math
from typing import Any, Iterable, Mapping

import cv2
import numpy as np


_CLASS_ALIASES = {
    "bus": "bus",
    "generator": "generator",
    "gen": "generator",
    "load": "load",
    "transformer": "transformer",
    "trans": "transformer",
}


def _normalise_class(value: Any) -> str:
    return _CLASS_ALIASES.get(str(value or "").strip().lower(), str(value or "").strip().lower())


def _unit_vector(vector: Iterable[float]) -> np.ndarray:
    values = np.asarray(tuple(vector), dtype=float).reshape(-1)
    if values.size < 2:
        return np.zeros(2, dtype=float)
    norm = float(np.hypot(values[0], values[1]))
    if norm <= 1e-6:
        return np.zeros(2, dtype=float)
    return values[:2] / norm


def _normalise_vector(vector: Iterable[float]) -> tuple[float, float]:
    value = _unit_vector(vector)
    return float(value[0]), float(value[1])


def _smoothed_direction(path: list[tuple[int, int]], lookback: int = 12) -> tuple[float, float]:
    if len(path) < 3:
        return 0.0, 0.0
    start_index = max(0, len(path) - lookback)
    return _normalise_vector(
        (path[-1][0] - path[start_index][0], path[-1][1] - path[start_index][1])
    )


def _angle_std(path: list[tuple[int, int]]) -> float:
    if len(path) < 3:
        return 0.0
    angles: list[float] = []
    for index in range(len(path) - 2):
        first, second, third = (
            np.asarray(path[index], dtype=float),
            np.asarray(path[index + 1], dtype=float),
            np.asarray(path[index + 2], dtype=float),
        )
        before = _unit_vector(second - first)
        after = _unit_vector(third - second)
        angles.append(float(np.arccos(np.clip(np.dot(before, after), -1.0, 1.0))))
    return float(np.std(angles)) if angles else 0.0


def _remove_numeric_text_components(binary: np.ndarray) -> np.ndarray:
    """Remove isolated label-like connected components before tracing.

    Bus numbers and parameter text are raster strokes too.  The heuristic is
    intentionally conservative: compact, tall, isolated glyphs disappear;
    long wires and bus bars remain in the conductor mask.
    """
    if binary is None or binary.ndim != 2:
        return binary

    height, width = binary.shape[:2]
    label_count, labels, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
    min_height = max(12, int(round(height * 0.015)))
    max_height = min(48, max(30, int(round(height * 0.08))))
    max_width = max(24, int(round(width * 0.03)))
    cleaned = binary.copy()

    for label in range(1, label_count):
        x, y, component_width, component_height, area = (int(value) for value in stats[label])
        del x, y
        if not (
            min_height <= component_height <= max_height
            and 3 <= component_width <= max_width
            and 25 <= area <= 450
        ):
            continue
        aspect = component_height / max(component_width, 1)
        density = area / max(component_width * component_height, 1)
        if 1.15 <= aspect <= 6.0 and 0.15 <= density <= 0.75:
            cleaned[labels == label] = 0

    return cleaned


def _bbox_xyxy(component: Mapping[str, Any]) -> tuple[float, float, float, float]:
    """Convert the public ``[cx, cy, width, height]`` box schema to xyxy."""
    bbox = component.get("bbox")
    if not isinstance(bbox, (tuple, list, np.ndarray)) or len(bbox) != 4:
        raise ValueError(f"component {component.get('id')!r} needs bbox=[cx, cy, width, height]")
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    if width <= 0 or height <= 0:
        raise ValueError(f"component {component.get('id')!r} has a non-positive bbox")
    return (
        centre_x - width / 2.0,
        centre_y - height / 2.0,
        centre_x + width / 2.0,
        centre_y + height / 2.0,
    )


def _project_to_segment(point: np.ndarray, first: Iterable[float], second: Iterable[float]) -> np.ndarray:
    first_array = np.asarray(tuple(first), dtype=float)
    second_array = np.asarray(tuple(second), dtype=float)
    axis = second_array - first_array
    denominator = float(np.dot(axis, axis))
    if denominator <= 1e-6:
        return first_array
    ratio = float(np.dot(point - first_array, axis) / denominator)
    return first_array + np.clip(ratio, 0.0, 1.0) * axis


def _load_port_metadata(
    component: Mapping[str, Any],
    load_ports: Mapping[str, Mapping[str, Any]] | None,
) -> Mapping[str, Any] | None:
    component_id = str(component["id"])
    if load_ports and component_id in load_ports:
        return load_ports[component_id]
    for key in ("connection_port", "load_port", "port"):
        metadata = component.get(key)
        if isinstance(metadata, Mapping):
            return metadata
    return None


def _make_component_ports(
    component: Mapping[str, Any],
    box: tuple[float, float, float, float],
    load_ports: Mapping[str, Mapping[str, Any]] | None,
) -> list[dict[str, Any]]:
    """Create physical connection ports for one detected object.

    Loads expose only their shaft/tail when tail geometry is supplied.  A
    transformer keeps its two opposite sides independently, whereas buses
    may accept conductors anywhere on their boundary.
    """
    component_id = str(component["id"])
    component_class = _normalise_class(component.get("class"))
    x1, y1, x2, y2 = box
    width = max(1.0, x2 - x1)
    height = max(1.0, y2 - y1)
    centre = np.asarray(((x1 + x2) / 2.0, (y1 + y2) / 2.0), dtype=float)

    if component_class == "load":
        metadata = _load_port_metadata(component, load_ports)
        if metadata is not None:
            point = metadata.get("point", metadata.get("base"))
            if point is not None:
                if metadata.get("outward_direction") is not None:
                    outward = _unit_vector(metadata["outward_direction"])
                else:
                    # ``direction`` is documented as tail -> arrowhead, so
                    # a conductor leaves in the opposite direction.
                    outward = -_unit_vector(metadata.get("direction", (0.0, 0.0)))
                if np.any(outward):
                    return [{
                        "component_id": component_id,
                        "side": "tail",
                        "mode": "fixed",
                        "point": np.asarray(point, dtype=float),
                        "direction": outward,
                        "max_distance": 34.0,
                    }]

        # A caller using only YOLO boxes can still obtain topology, but this
        # intentionally receives no directional priority.  CV tail geometry
        # is the reliable mode for load-to-bus attachment.
        return [{
            "component_id": component_id,
            "side": "boundary-fallback",
            "mode": "box_boundary",
            "box": box,
            "max_distance": 8.0,
        }]

    if component_class == "transformer":
        orientation = str(component.get("orientation", "")).strip().lower()
        if orientation not in {"horizontal", "vertical"}:
            orientation = "vertical" if height >= width else "horizontal"
        if orientation == "vertical":
            inset = min(width * 0.12, 8.0)
            return [
                {
                    "component_id": component_id,
                    "side": "top",
                    "mode": "segment",
                    "first": (x1 + inset, y1),
                    "second": (x2 - inset, y1),
                    "direction": np.asarray((0.0, -1.0)),
                    "max_distance": 14.0,
                },
                {
                    "component_id": component_id,
                    "side": "bottom",
                    "mode": "segment",
                    "first": (x1 + inset, y2),
                    "second": (x2 - inset, y2),
                    "direction": np.asarray((0.0, 1.0)),
                    "max_distance": 14.0,
                },
            ]
        inset = min(height * 0.12, 8.0)
        return [
            {
                "component_id": component_id,
                "side": "left",
                "mode": "segment",
                "first": (x1, y1 + inset),
                "second": (x1, y2 - inset),
                "direction": np.asarray((-1.0, 0.0)),
                "max_distance": 14.0,
            },
            {
                "component_id": component_id,
                "side": "right",
                "mode": "segment",
                "first": (x2, y1 + inset),
                "second": (x2, y2 - inset),
                "direction": np.asarray((1.0, 0.0)),
                "max_distance": 14.0,
            },
        ]

    if component_class == "generator":
        return [{
            "component_id": component_id,
            "side": "radial",
            "mode": "box_radial",
            "box": box,
            "centre": centre,
            "max_distance": 14.0,
        }]

    return [{
        "component_id": component_id,
        "side": "boundary",
        "mode": "box_boundary",
        "box": box,
        "max_distance": 10.0,
    }]


def _endpoint_tangent(skeleton: np.ndarray, endpoint: tuple[int, int]) -> np.ndarray:
    x, y = endpoint
    height, width = skeleton.shape[:2]
    neighbours: list[tuple[int, int]] = []
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dx == 0 and dy == 0:
                continue
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height and skeleton[ny, nx] == 255:
                neighbours.append((dx, dy))
    if not neighbours:
        return np.zeros(2, dtype=float)
    return _unit_vector(np.mean(np.asarray(neighbours, dtype=float), axis=0))


def _match_endpoint_to_port(
    endpoint: tuple[int, int],
    tangent: np.ndarray,
    port: Mapping[str, Any],
    component_class: str,
) -> dict[str, Any] | None:
    """Validate an endpoint by distance *and* its outward direction."""
    point = np.asarray(endpoint, dtype=float)
    mode = str(port["mode"])
    if mode == "fixed":
        port_point = np.asarray(port["point"], dtype=float)
        expected = _unit_vector(port["direction"])
    elif mode == "segment":
        port_point = _project_to_segment(point, port["first"], port["second"])
        expected = _unit_vector(port["direction"])
    else:
        x1, y1, x2, y2 = port["box"]
        port_point = np.asarray((np.clip(point[0], x1, x2), np.clip(point[1], y1, y2)), dtype=float)
        expected = _unit_vector(point - port["centre"]) if mode == "box_radial" else _unit_vector(tangent)

    delta = point - port_point
    distance = float(np.linalg.norm(delta))
    if mode == "box_boundary" and distance > 1.5:
        expected = _unit_vector(delta)
    radial_alignment = float(np.dot(_unit_vector(delta), expected)) if distance > 1.5 else 1.0
    tangent_alignment = float(np.dot(_unit_vector(tangent), expected))
    max_distance = float(port["max_distance"])
    if distance > max_distance:
        return None

    if mode in {"fixed", "segment"}:
        radial_limit = 0.48 if component_class == "load" else 0.22
        tangent_limit = 0.48 if component_class == "load" else 0.25
        short_transformer_bend = (
            component_class == "transformer"
            and distance <= 3.5
            and radial_alignment >= 0.65
        )
        if radial_alignment < radial_limit or (tangent_alignment < tangent_limit and not short_transformer_bend):
            return None
    elif mode == "box_radial" and tangent_alignment < 0.15 and distance > 3.0:
        return None

    distance_score = max(0.0, 1.0 - distance / max_distance)
    score = 0.48 * tangent_alignment + 0.37 * radial_alignment + 0.15 * distance_score
    if component_class == "load" and mode == "fixed" and distance <= 10.0:
        priority = 4
    elif component_class == "transformer" and mode == "segment" and distance <= 8.0:
        priority = 3
    elif component_class == "generator" and mode == "box_radial" and distance <= 10.0:
        priority = 2
    else:
        priority = 0
    return {
        "component_id": str(port["component_id"]),
        "side": str(port["side"]),
        "component_class": component_class,
        "priority": priority,
        "score": float(score),
        "distance": distance,
        "radial_alignment": radial_alignment,
        "tangent_alignment": tangent_alignment,
    }


def _assign_endpoints_to_ports(
    skeleton: np.ndarray,
    endpoints: set[tuple[int, int]],
    component_ports: Mapping[str, list[dict[str, Any]]],
    component_classes: Mapping[str, str],
) -> tuple[dict[tuple[int, int], str], dict[tuple[int, int], dict[str, Any]]]:
    endpoint_to_component: dict[tuple[int, int], str] = {}
    endpoint_to_port: dict[tuple[int, int], dict[str, Any]] = {}
    for endpoint in sorted(endpoints, key=lambda point: (point[1], point[0])):
        tangent = _endpoint_tangent(skeleton, endpoint)
        matches: list[dict[str, Any]] = []
        for component_id, ports in component_ports.items():
            component_class = component_classes[component_id]
            for port in ports:
                match = _match_endpoint_to_port(endpoint, tangent, port, component_class)
                if match is not None:
                    matches.append(match)
        if matches:
            best = max(matches, key=lambda match: (match["priority"], match["score"]))
            endpoint_to_component[endpoint] = best["component_id"]
            endpoint_to_port[endpoint] = best
    return endpoint_to_component, endpoint_to_port


def _find_best_exit(
    skeleton: np.ndarray,
    centre_x: int,
    centre_y: int,
    visited: set[tuple[int, int]],
    current_direction: tuple[float, float],
    radius: int = 12,
) -> list[tuple[int, int]]:
    height, width = skeleton.shape
    queue: deque[tuple[int, int, list[tuple[int, int]]]] = deque(
        [(centre_x, centre_y, [(centre_x, centre_y)])]
    )
    local_visited = {(centre_x, centre_y)}
    exits: list[tuple[int, int, list[tuple[int, int]]]] = []

    while queue:
        current_x, current_y, path = queue.popleft()
        if max(abs(current_x - centre_x), abs(current_y - centre_y)) >= radius:
            if len(path) >= 6:
                exits.append((current_x, current_y, path))
            continue
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                next_x, next_y = current_x + dx, current_y + dy
                next_point = (next_x, next_y)
                if (
                    0 <= next_x < width
                    and 0 <= next_y < height
                    and skeleton[next_y, next_x] == 255
                    and next_point not in visited
                    and next_point not in local_visited
                ):
                    local_visited.add(next_point)
                    queue.append((next_x, next_y, path + [next_point]))

    best_path: list[tuple[int, int]] = []
    best_score = -float("inf")
    for exit_x, exit_y, path in exits:
        lookahead = _normalise_vector((exit_x - centre_x, exit_y - centre_y))
        cosine = 1.0 if current_direction == (0.0, 0.0) else float(np.dot(current_direction, lookahead))
        if cosine < -0.2:
            continue
        score = cosine * 0.8 - _angle_std(path) * 0.2
        if score > best_score:
            best_score = score
            best_path = path
    return best_path


def _walk_skeleton_endpoint(
    skeleton: np.ndarray,
    start: tuple[int, int],
    source_component: str,
    endpoints: set[tuple[int, int]],
    endpoint_to_component: Mapping[tuple[int, int], str],
    used_endpoints: set[tuple[int, int]],
) -> tuple[str | None, tuple[int, int] | None, list[tuple[int, int]]]:
    """Follow one skeleton route while preserving its direction at branches."""
    height, width = skeleton.shape
    visited = {start}
    path = [start]
    current = start

    for _ in range(5000):
        centre_x, centre_y = current
        if current in endpoints and current != start:
            if current in used_endpoints:
                return None, None, []
            target = endpoint_to_component.get(current)
            if target and target != source_component:
                return target, current, path

        neighbours: list[tuple[int, int]] = []
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                next_x, next_y = centre_x + dx, centre_y + dy
                point = (next_x, next_y)
                if 0 <= next_x < width and 0 <= next_y < height and skeleton[next_y, next_x] == 255 and point not in visited:
                    neighbours.append(point)

        clusters: list[list[tuple[int, int]]] = []
        for neighbour in neighbours:
            for cluster in clusters:
                if any(max(abs(neighbour[0] - point[0]), abs(neighbour[1] - point[1])) <= 1 for point in cluster):
                    cluster.append(neighbour)
                    break
            else:
                clusters.append([neighbour])

        if len(clusters) == 1:
            choices = clusters[0]
            if len(choices) == 1:
                next_point = choices[0]
            else:
                direction = _smoothed_direction(path, lookback=8)
                next_point = max(
                    choices,
                    key=lambda point: 1.0 if direction == (0.0, 0.0) else float(np.dot(direction, _normalise_vector((point[0] - centre_x, point[1] - centre_y)))),
                )
            visited.add(next_point)
            path.append(next_point)
            current = next_point
            continue

        direction = _smoothed_direction(path, lookback=10)
        jump: tuple[int, int] | None = None
        if direction != (0.0, 0.0):
            radius_range = range(3, 13) if len(clusters) > 1 else range(2, 8)
            threshold = 0.95 if len(clusters) > 1 else 0.94
            for radius in radius_range:
                for dy in range(-radius, radius + 1):
                    for dx in range(-radius, radius + 1):
                        if max(abs(dx), abs(dy)) != radius:
                            continue
                        next_x, next_y = centre_x + dx, centre_y + dy
                        point = (next_x, next_y)
                        if not (0 <= next_x < width and 0 <= next_y < height):
                            continue
                        if skeleton[next_y, next_x] != 255 or point in visited:
                            continue
                        cosine = float(np.dot(direction, _normalise_vector((dx, dy))))
                        if cosine > threshold:
                            threshold = cosine
                            jump = point
                if jump is not None:
                    break

        if jump is not None:
            distance = max(1, int(math.hypot(jump[0] - centre_x, jump[1] - centre_y)))
            for step in range(1, distance + 1):
                point = (
                    int(centre_x + (jump[0] - centre_x) * (step / distance)),
                    int(centre_y + (jump[1] - centre_y) * (step / distance)),
                )
                visited.add(point)
                path.append(point)
            current = jump
            continue

        if len(clusters) > 1:
            exit_path = _find_best_exit(skeleton, centre_x, centre_y, visited, direction)
            if len(exit_path) > 1:
                for point in exit_path[1:]:
                    visited.add(point)
                    path.append(point)
                current = exit_path[-1]
                continue
        break

    return None, None, []


def _path_length(path: list[tuple[int, int]]) -> float:
    return sum(
        float(np.hypot(path[index][0] - path[index - 1][0], path[index][1] - path[index - 1][1]))
        for index in range(1, len(path))
    )


def _validated_load_fallbacks(
    candidates: list[dict[str, Any]],
    component_boxes: Mapping[str, tuple[float, float, float, float]],
    component_classes: Mapping[str, str],
    components: Mapping[str, Mapping[str, Any]],
    load_ports: Mapping[str, Mapping[str, Any]] | None,
) -> list[dict[str, Any]]:
    """Retain a CV-validated load-to-bus lead if masking erased its endpoint."""
    result = list(candidates)
    for component_id, component in components.items():
        if component_classes[component_id] != "load":
            continue
        metadata = _load_port_metadata(component, load_ports)
        if metadata is None:
            continue
        bus_id = metadata.get("attached_bus_id")
        point = metadata.get("point", metadata.get("base"))
        if bus_id is None or point is None:
            continue
        bus_id = str(bus_id)
        if bus_id not in component_boxes:
            continue
        outward = metadata.get("outward_direction")
        direction = (
            _unit_vector(outward)
            if outward is not None
            else -_unit_vector(metadata.get("direction", (0.0, 0.0)))
        )
        if not np.any(direction):
            continue
        already_connected = any(
            component_id in candidate["connected_to"]
            and any(component_classes.get(other) == "bus" for other in candidate["connected_to"] if other != component_id)
            for candidate in result
        )
        if already_connected:
            continue

        x1, y1, x2, y2 = component_boxes[bus_id]
        start = np.asarray(point, dtype=float)
        if abs(direction[1]) >= abs(direction[0]):
            target = np.asarray((float(np.clip(start[0], x1, x2)), y2 if direction[1] < 0 else y1))
            if abs(target[0] - start[0]) > 3.0:
                continue
        else:
            target = np.asarray((x2 if direction[0] < 0 else x1, float(np.clip(start[1], y1, y2))))
            if abs(target[1] - start[1]) > 3.0:
                continue
        distance = float(np.linalg.norm(target - start))
        if distance < 3.0:
            continue
        path: list[tuple[int, int]] = []
        for step in range(int(math.ceil(distance)) + 1):
            point_at_step = start + direction * min(float(step), distance)
            item = int(round(point_at_step[0])), int(round(point_at_step[1]))
            if not path or path[-1] != item:
                path.append(item)
        result.append({
            "connected_to": [component_id, bus_id],
            "path": path,
            "connection_score": 0.96,
            "source_port": "tail",
            "target_port": "boundary",
            "port_distances": {component_id: 0.0, bus_id: 0.0},
            "trace_method": "validated_load_bus_attachment",
        })
    return result


def _keep_single_terminal_components(
    candidates: list[dict[str, Any]],
    component_classes: Mapping[str, str],
) -> list[dict[str, Any]]:
    """Keep only the best physical shaft for each load/generator.

    Bus bars and transformer ports deliberately remain unlimited: real SLDs
    can have several lines on a bus and two transformer sides are distinct.
    """
    keep = set(range(len(candidates)))
    for component_id, component_class in component_classes.items():
        if component_class not in {"load", "generator"}:
            continue
        incident = [index for index, item in enumerate(candidates) if component_id in item["connected_to"]]
        if len(incident) <= 1:
            continue
        if component_class == "load":
            bus_incident = [
                index
                for index in incident
                if any(component_classes.get(other) == "bus" for other in candidates[index]["connected_to"] if other != component_id)
            ]
            preferred = bus_incident or incident
        else:
            preferred = incident

        if component_class == "generator":
            best = max(
                preferred,
                key=lambda index: (
                    -float(candidates[index].get("port_distances", {}).get(component_id, float("inf"))),
                    float(candidates[index]["connection_score"]),
                    len(candidates[index]["path"]),
                ),
            )
        else:
            best = max(
                preferred,
                key=lambda index: (float(candidates[index]["connection_score"]), -len(candidates[index]["path"])),
            )
        keep.difference_update(index for index in incident if index != best)
    return [item for index, item in enumerate(candidates) if index in keep]


def _thin(binary: np.ndarray) -> np.ndarray:
    """Use OpenCV-contrib thinning when present, otherwise morphologically thin."""
    try:
        return cv2.ximgproc.thinning(binary, thinningType=cv2.ximgproc.THINNING_GUOHALL)
    except AttributeError:
        skeleton = np.zeros_like(binary)
        remaining = binary.copy()
        element = cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3))
        while cv2.countNonZero(remaining) > 0:
            eroded = cv2.erode(remaining, element)
            opened = cv2.dilate(eroded, element)
            skeleton = cv2.bitwise_or(skeleton, cv2.subtract(remaining, opened))
            remaining = eroded
        return skeleton


def _find_endpoints(skeleton: np.ndarray) -> set[tuple[int, int]]:
    height, width = skeleton.shape[:2]
    endpoints: set[tuple[int, int]] = set()
    for y in range(1, height - 1):
        for x in range(1, width - 1):
            if skeleton[y, x] != 255:
                continue
            neighbours = int(np.count_nonzero(skeleton[y - 1:y + 2, x - 1:x + 2])) - 1
            if neighbours == 1:
                endpoints.add((x, y))
    return endpoints


def extract_port_aware_topology(
    image: np.ndarray,
    components: Iterable[Mapping[str, Any]],
    *,
    load_ports: Mapping[str, Mapping[str, Any]] | None = None,
    remove_numeric_text: bool = True,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Extract port-validated electrical connections from an SLD image.

    ``image`` must be an OpenCV BGR image.  The result is ``(lines, debug)``;
    each line has ``line_id``, ``connected_to``, ``path``, source/target port,
    and a trace method.  ``debug`` exposes the binary/skeleton masks for
    diagnostics but is not intended as JSON output.
    """
    if image is None or image.ndim != 3:
        raise ValueError("image must be a non-empty BGR image")

    component_map: dict[str, Mapping[str, Any]] = {}
    component_boxes: dict[str, tuple[float, float, float, float]] = {}
    component_classes: dict[str, str] = {}
    for component in components:
        if "id" not in component or "class" not in component:
            raise ValueError("every component needs id, class, and bbox")
        component_id = str(component["id"])
        if component_id in component_map:
            raise ValueError(f"duplicate component id: {component_id}")
        component_map[component_id] = component
        component_boxes[component_id] = _bbox_xyxy(component)
        component_classes[component_id] = _normalise_class(component["class"])

    if not component_map:
        return [], {"binary": None, "skeleton": None, "endpoints": set()}

    image_height, image_width = image.shape[:2]
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    _, global_binary = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)
    adaptive_binary = cv2.adaptiveThreshold(
        gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 15, 10
    )
    binary = cv2.bitwise_and(global_binary, adaptive_binary)
    if remove_numeric_text:
        binary = _remove_numeric_text_components(binary)

    # Remove detected symbols so their internal strokes cannot become wires.
    for component_id, box in component_boxes.items():
        x1, y1, x2, y2 = box
        padding = 1 if component_classes[component_id] == "bus" else 0
        cv2.rectangle(
            binary,
            (max(0, int(math.floor(x1)) - padding), max(0, int(math.floor(y1)) - padding)),
            (min(image_width - 1, int(math.ceil(x2)) + padding), min(image_height - 1, int(math.ceil(y2)) + padding)),
            0,
            -1,
        )

    binary_closed = cv2.morphologyEx(
        binary,
        cv2.MORPH_CLOSE,
        cv2.getStructuringElement(cv2.MORPH_RECT, (2, 2)),
    )
    skeleton = _thin(binary_closed)
    endpoints = _find_endpoints(skeleton)
    component_ports = {
        component_id: _make_component_ports(component, component_boxes[component_id], load_ports)
        for component_id, component in component_map.items()
    }
    endpoint_to_component, endpoint_to_port = _assign_endpoints_to_ports(
        skeleton, endpoints, component_ports, component_classes
    )

    candidates: list[dict[str, Any]] = []
    used_endpoints: set[tuple[int, int]] = set()
    for start, source_id in sorted(endpoint_to_component.items(), key=lambda item: (item[0][1], item[0][0])):
        if start in used_endpoints:
            continue
        target_id, target_endpoint, path = _walk_skeleton_endpoint(
            skeleton, start, source_id, endpoints, endpoint_to_component, used_endpoints
        )
        if target_id is None or target_endpoint is None or target_endpoint in used_endpoints:
            continue
        connected_classes = {component_classes.get(source_id, ""), component_classes.get(target_id, "")}
        minimum_length = 3.0 if connected_classes.intersection({"load", "generator"}) else 12.0
        if _path_length(path) < minimum_length:
            continue
        used_endpoints.update((start, target_endpoint))
        source_port = endpoint_to_port.get(start, {})
        target_port = endpoint_to_port.get(target_endpoint, {})
        candidates.append({
            "connected_to": [source_id, target_id],
            "path": [(int(x), int(y)) for x, y in path],
            "connection_score": min(float(source_port.get("score", 0.0)), float(target_port.get("score", 0.0))),
            "port_distances": {
                source_id: float(source_port.get("distance", float("inf"))),
                target_id: float(target_port.get("distance", float("inf"))),
            },
            "source_port": source_port.get("side"),
            "target_port": target_port.get("side"),
            "trace_method": "skeleton",
        })

    candidates = _validated_load_fallbacks(
        candidates, component_boxes, component_classes, component_map, load_ports
    )
    candidates = _keep_single_terminal_components(candidates, component_classes)
    lines = [
        {
            "line_id": f"L{index + 1}",
            "connected_to": candidate["connected_to"],
            "path": candidate["path"],
            "source_port": candidate["source_port"],
            "target_port": candidate["target_port"],
            "trace_method": candidate["trace_method"],
        }
        for index, candidate in enumerate(candidates)
    ]
    debug = {
        "binary": binary,
        "skeleton": skeleton,
        "endpoints": endpoints,
        "endpoint_to_component": endpoint_to_component,
        "endpoint_to_port": endpoint_to_port,
        "component_ports": component_ports,
        "line_candidates": candidates,
    }
    return lines, debug


def draw_topology_overlay(
    image: np.ndarray,
    lines: Iterable[Mapping[str, Any]],
    *,
    color: tuple[int, int, int] = (0, 0, 255),
    thickness: int = 2,
) -> np.ndarray:
    """Draw traced paths and line IDs in red by default for visual review."""
    output = image.copy()
    for line in lines:
        path = np.asarray(line.get("path", ()), dtype=np.int32)
        if len(path) < 2:
            continue
        cv2.polylines(output, [path.reshape(-1, 1, 2)], False, color, thickness, cv2.LINE_AA)
        midpoint = path[len(path) // 2]
        cv2.putText(
            output,
            str(line.get("line_id", "L")),
            (int(midpoint[0]) + 3, int(midpoint[1]) - 3),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.4,
            color,
            1,
            cv2.LINE_AA,
        )
    return output

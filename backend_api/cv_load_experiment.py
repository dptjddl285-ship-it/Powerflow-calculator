"""OpenCV detector for arrow/triangle load symbols.

The detector intentionally does not use YOLO.  It accepts filled or outline
arrowheads only after the opposite side is traced to a CV-detected bus bar;
short routed bends are allowed, while tiny text-like contours are filtered.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from pathlib import Path
import csv

import cv2
import numpy as np

import cv_bus_refined_experiment as bus_cv


ROOT = Path(__file__).resolve().parent.parent
INPUT_NAMES = ("IEEE24bus.jpg", "2026-7-01-1.jpg", "39bus.jpg", "2026-7-01-8.jpg")
OUTPUT = ROOT / "cv_load_comparison"
SCALE = bus_cv.SCALE
FALLBACK_MIN_ARROW_SIDE = 4  # scaled pixels; only used when normal CV finds no loads


@dataclass
class LoadCandidate:
    x: int
    y: int
    w: int
    h: int
    tip: tuple[float, float]
    base: tuple[float, float]
    direction: tuple[int, int]
    triangle_score: float
    lead_length: int = 0
    attached_bus: int | None = None
    reason: str = "candidate"
    core_contour: np.ndarray | None = None
    trace_start_offset: int | None = None
    # Pixel path (in SCALE coordinates) that actually proved the load reaches
    # its attached bus.  Keeping the evidence lets topology reuse a routed or
    # bent lead instead of replacing it with a guessed straight segment.
    attachment_path: list[tuple[int, int]] | None = None


def _source_ink_path_within_trace_corridor(
    source_skeleton: np.ndarray,
    traced_path: list[tuple[int, int]],
) -> list[tuple[int, int]]:
    """Recover a connected path using only source skeleton pixels.

    The permissive BFS may walk one pixel beside the source because its search
    mask is dilated. Its route defines only a narrow corridor; this second BFS
    is constrained to undilated ink inside that corridor, so every returned
    point is an actual source-skeleton pixel.
    """
    if len(traced_path) < 2:
        return []
    source = np.where(source_skeleton > 0, 255, 0).astype(np.uint8)
    corridor = np.zeros_like(source)
    points = np.asarray(traced_path, dtype=np.int32).reshape(-1, 1, 2)
    cv2.polylines(corridor, [points], False, 255, 3, cv2.LINE_8)
    allowed = (source > 0) & (corridor > 0)
    height, width = source.shape[:2]

    def nearby(point: tuple[int, int]) -> list[tuple[int, int]]:
        x, y = point
        result = []
        for candidate_y in range(max(0, y - 2), min(height, y + 3)):
            for candidate_x in range(max(0, x - 2), min(width, x + 3)):
                if allowed[candidate_y, candidate_x]:
                    result.append((candidate_x, candidate_y))
        return sorted(
            result,
            key=lambda item: (item[0] - x) ** 2 + (item[1] - y) ** 2,
        )

    starts = nearby(traced_path[0])
    targets = set(nearby(traced_path[-1]))
    if not starts or not targets:
        return []

    queue: deque[tuple[int, int]] = deque(starts)
    parents: dict[tuple[int, int], tuple[int, int] | None] = {
        start: None for start in starts
    }
    directions = (
        (-1, -1), (0, -1), (1, -1),
        (-1, 0),           (1, 0),
        (-1, 1),  (0, 1),  (1, 1),
    )
    reached = None
    while queue:
        point = queue.popleft()
        if point in targets:
            reached = point
            break
        x, y = point
        for dx, dy in directions:
            next_point = (x + dx, y + dy)
            next_x, next_y = next_point
            if not (0 <= next_x < width and 0 <= next_y < height):
                continue
            if not allowed[next_y, next_x] or next_point in parents:
                continue
            parents[next_point] = point
            queue.append(next_point)
    if reached is None:
        return []

    path = []
    cursor: tuple[int, int] | None = reached
    while cursor is not None:
        path.append(cursor)
        cursor = parents[cursor]
    path.reverse()
    return path


def _attachment_implied_arrow_direction(
    path: list[tuple[int, int]],
    thin_width: int,
) -> tuple[int, int] | None:
    """Infer arrow direction from the first stable bus-facing lead segment."""
    if len(path) < 4:
        return None
    lookahead = min(len(path) - 1, max(4, int(thin_width) * 2))
    start_x, start_y = path[0]
    end_x, end_y = path[lookahead]
    delta_x = end_x - start_x
    delta_y = end_y - start_y
    horizontal = abs(delta_x)
    vertical = abs(delta_y)
    if max(horizontal, vertical) < 3:
        return None
    # Ambiguous diagonal starts belong to routed bends and should retain their
    # contour-derived orientation. Correct only a clearly cardinal shaft.
    if horizontal >= vertical * 1.5:
        lead_direction = (int(np.sign(delta_x)), 0)
    elif vertical >= horizontal * 1.5:
        lead_direction = (0, int(np.sign(delta_y)))
    else:
        return None
    return (-lead_direction[0], -lead_direction[1])


def _set_candidate_direction(candidate: LoadCandidate, direction: tuple[int, int]) -> None:
    """Update cardinal tip/base geometry after lead-backed orientation repair."""
    centre_x = float(candidate.x) + float(candidate.w) / 2.0
    centre_y = float(candidate.y) + float(candidate.h) / 2.0
    direction_x, direction_y = direction
    if direction_x > 0:
        candidate.tip = (float(candidate.x + candidate.w), centre_y)
        candidate.base = (float(candidate.x), centre_y)
    elif direction_x < 0:
        candidate.tip = (float(candidate.x), centre_y)
        candidate.base = (float(candidate.x + candidate.w), centre_y)
    elif direction_y > 0:
        candidate.tip = (centre_x, float(candidate.y + candidate.h))
        candidate.base = (centre_x, float(candidate.y))
    else:
        candidate.tip = (centre_x, float(candidate.y))
        candidate.base = (centre_x, float(candidate.y + candidate.h))
    candidate.direction = direction


def read_image(path: Path) -> np.ndarray:
    image = cv2.imdecode(np.fromfile(str(path), dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise FileNotFoundError(path)
    return image


def find_input(name: str) -> Path:
    paths = list(ROOT.rglob(name))
    if not paths:
        raise FileNotFoundError(name)
    return paths[0]


def _triangle_arrow_geometries(
    points: np.ndarray,
) -> list[tuple[tuple[float, float], tuple[float, float], tuple[int, int]]]:
    """Infer an up/down/left/right arrow from its aligned base vertices.

    Neither the smallest triangle angle nor the longest edge is stable across
    scans.  For a cardinal arrow, however, its two base vertices lie at nearly
    the same coordinate along the pointing axis, while the tip is the lone
    extreme vertex.  That holds for wide, narrow, and near-equilateral heads.
    """
    vertices = points.reshape(-1, 2).astype(float)
    if len(vertices) not in (3, 4):
        return []
    options: list[tuple[float, tuple[float, float], tuple[float, float], tuple[int, int]]] = []
    directions = ((1, 0), (-1, 0), (0, 1), (0, -1))
    for direction in directions:
        vector = np.asarray(direction, dtype=float)
        perpendicular = np.asarray((-direction[1], direction[0]), dtype=float)
        projection = vertices @ vector
        tip_index = int(np.argmax(projection))
        remaining = [index for index in range(len(vertices)) if index != tip_index]
        for left_index in range(len(remaining)):
            for right_index in range(left_index + 1, len(remaining)):
                base_indices = (remaining[left_index], remaining[right_index])
                tip_extent = projection[tip_index] - float(np.mean(projection[list(base_indices)]))
                base_axis_spread = abs(projection[base_indices[0]] - projection[base_indices[1]])
                base_width = abs(float(np.dot(
                    vertices[base_indices[0]] - vertices[base_indices[1]], perpendicular
                )))
                if tip_extent <= 0 or base_width <= 0:
                    continue
                alignment = base_axis_spread / base_width
                # Prefer aligned bases, then the direction with a clear tip.
                score = alignment - min(tip_extent / base_width, 1.5) * 0.05
                if score <= 0.38:
                    tip = tuple(vertices[tip_index])
                    base = tuple(np.mean(vertices[list(base_indices)], axis=0))
                    options.append((score, tip, base, direction))
    # A four-corner head+stem silhouette can have two plausible geometric
    # directions.  Keep both; lead-to-bus tracing below chooses the physical
    # direction instead of committing from shape alone.
    options.sort(key=lambda item: item[0])
    unique: list[tuple[tuple[float, float], tuple[float, float], tuple[int, int]]] = []
    for _, tip, base, direction in options:
        if direction not in [saved[2] for saved in unique]:
            unique.append((tip, base, direction))
    return unique


def _small_arrow_axis_geometries(
    x: int,
    y: int,
    w: int,
    h: int,
    fill_ratio: float,
) -> list[tuple[tuple[float, float], tuple[float, float], tuple[int, int]]]:
    """Add a coarse axis estimate for tiny, partially rasterized arrowheads.

    At 2x scale a V-shaped head can collapse to a rectangle/quad, so the
    polygon alignment test cannot always identify its tip.  Its aspect ratio
    still tells us whether it is a vertical head.  The bus-attachment trace
    below is the final physical validation, so both vertical directions are
    intentionally offered here.
    """
    if fill_ratio < 0.28:
        return []
    center_x = x + w / 2.0
    center_y = y + h / 2.0
    if h >= w * 1.20:
        return [
            ((center_x, y + h - 0.25), (center_x, y + 0.25), (0, 1)),
            ((center_x, y + 0.25), (center_x, y + h - 0.25), (0, -1)),
        ]
    if w >= h * 1.20:
        return [
            ((x + w - 0.25, center_y), (x + 0.25, center_y), (1, 0)),
            ((x + 0.25, center_y), (x + w - 0.25, center_y), (-1, 0)),
        ]
    return []


def triangle_candidates(
    binary: np.ndarray,
    thin_width: int,
    small_arrow_mode: bool = False,
) -> tuple[list[LoadCandidate], list[LoadCandidate]]:
    """Find filled three-vertex cores while discarding bars and text."""
    distance = cv2.distanceTransform(binary, cv2.DIST_L2, 3)
    candidates: list[LoadCandidate] = []
    rejected: list[LoadCandidate] = []
    image_h, image_w = binary.shape
    # The normal pass matches the validated IEEE sheets.  A separate fallback
    # pass is reserved for scans whose small V-shaped arrowheads disappear at
    # the normal distance-transform threshold.
    if small_arrow_mode:
        factors = (0.55, 0.60, 0.65, 0.70, 0.82, 1.0, 1.25, 1.5)
        min_core_radius = 2.0
        min_side = FALLBACK_MIN_ARROW_SIDE
        min_fill, max_fill = 0.22, 0.62
    else:
        factors = (0.82, 1.0, 1.25, 1.5)
        min_core_radius = 3.0
        min_side = max(8, thin_width * 2)
        min_fill, max_fill = 0.30, 0.52
    # A single threshold fails when the printed arrow stem is almost as thick
    # as its head.  At stronger thresholds the head separates again.  Each
    # valid candidate is deduplicated below, so this is not multiple voting.
    for factor in factors:
        core_radius = max(min_core_radius, thin_width * factor)
        thick_core = np.where(distance >= core_radius, 255, 0).astype(np.uint8)
        thick_core = cv2.morphologyEx(
            thick_core,
            cv2.MORPH_CLOSE,
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)),
        )
        contours, _ = cv2.findContours(thick_core, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for contour in contours:
            x, y, w, h = cv2.boundingRect(contour)
            area = float(cv2.contourArea(contour))
            perimeter = float(cv2.arcLength(contour, True))
            hull = cv2.convexHull(contour)
            polygon = cv2.approxPolyDP(hull, 0.075 * perimeter, True)
            fill_ratio = area / max(w * h, 1)
            max_size, min_size = max(w, h), min(w, h)
            if min_size < min_side:
                continue
            if max_size > min(image_w, image_h) * 0.10:
                continue
            max_aspect_ratio = 3.20 if small_arrow_mode else 2.35
            if max_size / max(min_size, 1) > max_aspect_ratio:
                continue
            # Ground bars tend to form very dense rectangular blobs after
            # thresholding; real arrowheads consistently stay below this.
            if not min_fill <= fill_ratio <= max_fill:
                continue
            if len(polygon) not in (3, 4):
                continue
            geometries = _triangle_arrow_geometries(polygon)
            if small_arrow_mode:
                existing_directions = {direction for _, _, direction in geometries}
                for geometry in _small_arrow_axis_geometries(x, y, w, h, fill_ratio):
                    if geometry[2] not in existing_directions:
                        geometries.append(geometry)
                        existing_directions.add(geometry[2])
            for tip, base, direction in geometries:
                candidates.append(LoadCandidate(
                    x=x, y=y, w=w, h=h, tip=tip, base=base,
                    direction=direction, triangle_score=fill_ratio,
                    core_contour=contour.reshape(-1, 2).astype(np.int32).copy(),
                ))

    deduplicated: list[LoadCandidate] = []
    for candidate in candidates:
        center = np.asarray((candidate.x + candidate.w / 2, candidate.y + candidate.h / 2))
        duplicate_index = None
        for index, saved in enumerate(deduplicated):
            saved_center = np.asarray((saved.x + saved.w / 2, saved.y + saved.h / 2))
            threshold = max(candidate.w, candidate.h, saved.w, saved.h) * 0.65
            if (
                candidate.direction == saved.direction
                and float(np.linalg.norm(center - saved_center)) <= threshold
            ):
                duplicate_index = index
                break
        if duplicate_index is None:
            deduplicated.append(candidate)
        elif candidate.w * candidate.h > deduplicated[duplicate_index].w * deduplicated[duplicate_index].h:
            deduplicated[duplicate_index] = candidate
    return deduplicated, rejected


def _scaled_bus_boxes(
    image: np.ndarray,
    bus_records: list[dict] | None = None,
) -> list[tuple[int, int, int, int]]:
    """Return one scaled bus coordinate system for every load decision.

    ``detect_cv_buses`` has a final family/reconstruction pass that can recover
    bars missed by the older morphology-only call.  Loads must validate their
    tails against those same final bars; otherwise a physically connected arrow
    is incorrectly rejected simply because its bus was absent from a second,
    independently generated list.

    ``bus_records`` uses the public CV-bus ``x/y/w/h`` geometry.  The optional
    default preserves the standalone experiment script behaviour.
    """
    boxes = []
    for bus in (bus_records if bus_records is not None else bus_cv.detect_cv_buses(image)):
        x = float(bus["x"]) * SCALE
        y = float(bus["y"]) * SCALE
        w = float(bus["w"]) * SCALE
        h = float(bus["h"]) * SCALE
        boxes.append((
            int(round(x - w / 2)), int(round(y - h / 2)),
            int(round(x + w / 2)), int(round(y + h / 2)),
        ))
    return boxes


def _point_inside_box(point: tuple[float, float], box: tuple[int, int, int, int], margin: int) -> bool:
    x, y = point
    x1, y1, x2, y2 = box
    return x1 - margin <= x <= x2 + margin and y1 - margin <= y <= y2 + margin


def _line_ink(binary: np.ndarray, x: int, y: int, direction: tuple[int, int], thin_width: int) -> bool:
    """Check a small perpendicular strip so anti-aliasing does not break a lead."""
    h, w = binary.shape
    dx, dy = direction
    radius = max(1, thin_width // 2)
    if dx:
        y1, y2 = max(0, y - radius), min(h, y + radius + 1)
        x1, x2 = max(0, x - 1), min(w, x + 2)
    else:
        y1, y2 = max(0, y - 1), min(h, y + 2)
        x1, x2 = max(0, x - radius), min(w, x + radius + 1)
    return bool(np.any(binary[y1:y2, x1:x2]))


def _tip_has_external_continuation(
    binary: np.ndarray,
    candidate: LoadCandidate,
    thin_width: int,
) -> bool:
    """Reject a flow arrow embedded in a through conductor.

    A load is a pendant device: its shaft/tail reaches one bus, but ink must
    not continue beyond the arrow tip.  A directional flow marker on a line
    has exactly the opposite topology and otherwise resembles the same small
    filled triangle.  Probe the forward axis and its two 45-degree neighbours
    so an oblique through-line is not missed.
    """
    dx, dy = candidate.direction
    if (dx, dy) not in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        return False
    if dx:
        rays = ((dx, 0), (dx, -1), (dx, 1))
    else:
        rays = ((0, dy), (-1, dy), (1, dy))
    height, width = binary.shape[:2]
    # ``candidate.tip`` comes from the distance-transform core, which lies
    # inside the printed arrowhead.  Start beyond that core before asking
    # whether a conductor continues.  Otherwise the outer half of a large,
    # perfectly terminal arrow is mistaken for a through-line (especially
    # when a P/Q label is printed just below it).
    axis_extent = candidate.w if dx else candidate.h
    start = max(3, thin_width, int(round(axis_extent * 0.42)))
    stop = max(start + 6, thin_width * 3)
    radius = max(1, int(round(thin_width * 0.40)))
    for ray_x, ray_y in rays:
        hits = 0
        tested = 0
        initial_run = 0
        still_adjacent = True
        for distance in range(start, stop + 1):
            x = int(round(candidate.tip[0] + ray_x * distance))
            y = int(round(candidate.tip[1] + ray_y * distance))
            if not (0 <= x < width and 0 <= y < height):
                break
            tested += 1
            has_ink = bool(np.any(binary[
                max(0, y - radius):min(height, y + radius + 1),
                max(0, x - radius):min(width, x + radius + 1),
            ]))
            if has_ink:
                hits += 1
                if still_adjacent:
                    initial_run += 1
            else:
                still_adjacent = False
        # A label can sit above an arrowhead on the same axis.  It may occupy
        # enough sampled pixels to pass a simple hit ratio, but it cannot form
        # a continuous conductor immediately after the tip.  A real flow
        # marker on a through line does, so require both local continuity and
        # sustained ink farther along the ray.
        if (
            tested
            and initial_run >= max(3, int(round(thin_width * 0.5)))
            and hits / tested >= 0.50
        ):
            return True
    return False


def _valid_pendant_load(
    binary: np.ndarray,
    candidate: LoadCandidate,
    thin_width: int,
    *,
    check_tip_continuation: bool = True,
) -> bool:
    """Apply object-level checks shared by direct and traced load paths."""
    connection_reason = str(candidate.reason)
    if check_tip_continuation and _tip_has_external_continuation(
        binary, candidate, thin_width
    ):
        candidate.reason = "rejected: arrow tip continues into a through conductor"
        return False
    # A load feeder is local to its bus.  A long skeleton walk from a small
    # triangle is almost always a number or a directional flow marker that
    # wandered into the rest of the network.
    maximum_lead = max(160, thin_width * 28)
    # A straight, axis-aligned feeder may legitimately be long.  The length
    # guard exists only for a graph walk that can turn through labels and
    # unrelated ink; direct electrical continuity does not need a page-scale
    # distance cutoff.
    if candidate.lead_length > maximum_lead and "traced" in connection_reason:
        candidate.reason = "rejected: pendant lead is implausibly long"
        return False
    # The distance-transform core represents the arrowhead, not a bus or a
    # full conductor segment.  A very large core is therefore a bar/line
    # fragment rather than a compact device symbol.
    maximum_core = max(96, int(round(min(binary.shape) * 0.08)))
    if max(candidate.w, candidate.h) > maximum_core:
        candidate.reason = "rejected: load core is too large"
        return False
    return True


def _short_aligned_bus_target(
    binary: np.ndarray,
    candidate: LoadCandidate,
    bus_boxes: list[tuple[int, int, int, int]],
    thin_width: int,
) -> tuple[int, int] | None:
    """Return a nearby bus for a solid arrow whose lead is too short to trace.

    Some scans print the arrowhead almost directly against the bus.  In those
    cases there may be fewer than three continuous lead-widths of pixels, so
    the normal ink trace intentionally rejects it.  Geometry-only acceptance
    would promote digits, therefore this exception is limited to a reasonably
    large filled core, a triangle score, and a hole-free glyph whose reverse
    axis lands inside a CV bus within a short distance.
    """
    if candidate.direction not in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        return None
    if min(candidate.w, candidate.h) < max(18, thin_width * 3):
        return None
    if candidate.triangle_score < 0.38:
        return None
    if _has_enclosed_ink_hole(binary, candidate, thin_width):
        return None

    start_offset = max(1, int(round(max(candidate.w, candidate.h) * 0.36)))
    short_limit = max(30, int(round(max(candidate.w, candidate.h) * 0.85)))
    lead_direction = (-candidate.direction[0], -candidate.direction[1])
    for distance in range(start_offset, short_limit + 1):
        point = (
            candidate.base[0] + lead_direction[0] * distance,
            candidate.base[1] + lead_direction[1] * distance,
        )
        for index, box in enumerate(bus_boxes):
            if _point_inside_box(point, box, margin=max(3, thin_width)):
                return index, distance
    return None


def attach_to_bus(
    binary: np.ndarray,
    candidate: LoadCandidate,
    bus_boxes: list[tuple[int, int, int, int]],
    thin_width: int,
) -> bool:
    """Trace the lead from the triangle base directly to a nearby bus bar."""
    h, w = binary.shape
    arrow_dx, arrow_dy = candidate.direction
    lead_direction = (-arrow_dx, -arrow_dy)
    # The thick-core base is slightly inside the original triangle.  Move past
    # it before checking the thin lead.
    start_offset = (
        max(1, int(candidate.trace_start_offset))
        if candidate.trace_start_offset is not None
        else max(3, int(round(max(candidate.w, candidate.h) * 0.36)))
    )
    max_distance = max(48, min(h, w) // 4)
    min_lead = 12  # scaled pixels; rejects text touching a bus edge
    missing_run = 0
    consecutive_ink = 0
    longest_ink_run = 0
    # JPEG compression and faint scans occasionally erase a short segment
    # immediately before a bus (notably the 39-bus loads at buses 1 and 13).
    # Keep tracing on the same axis for a bounded gap; this is still stricter
    # than a free spatial-nearness match because the candidate direction and
    # the bus intersection must agree.
    normal_missing_run = max(3, thin_width)
    max_missing_run = max(thin_width * 8, int(round(max(candidate.w, candidate.h) * 3.0)))
    orphan_endpoint_candidate = (
        candidate.direction[1]
        and candidate.w >= thin_width * 3
        and candidate.h >= thin_width * 4
        and candidate.h / max(candidate.w, 1) >= 1.10
    )
    short_bus_target = _short_aligned_bus_target(
        binary, candidate, bus_boxes, thin_width
    )
    if short_bus_target is not None:
        bus_index, distance = short_bus_target
        candidate.lead_length = distance
        candidate.attached_bus = bus_index
        candidate.reason = "accepted: short aligned lead reaches CV bus"
        return True

    for distance in range(start_offset, max_distance):
        x = int(round(candidate.base[0] + lead_direction[0] * distance))
        y = int(round(candidate.base[1] + lead_direction[1] * distance))
        if not (0 <= x < w and 0 <= y < h):
            break
        for index, box in enumerate(bus_boxes):
            if _point_inside_box((x, y), box, margin=max(3, thin_width)):
                if distance < min_lead:
                    candidate.reason = "rejected: lead too short (text/ground edge)"
                    return False
                # A long, visible lead followed by a small scan gap is safe
                # to recover.  If the lead itself vanished, allow recovery
                # only for a sufficiently large vertical arrow precisely
                # aligned with a nearby bus end (39-bus bus 1 style).
                recovered_visible_lead = longest_ink_run >= thin_width * 3
                near_bus_endpoint_arrow = (
                    orphan_endpoint_candidate
                    and distance <= max(thin_width * 12, int(round(max(candidate.w, candidate.h) * 3.0)))
                )
                if recovered_visible_lead or near_bus_endpoint_arrow:
                    candidate.lead_length = distance
                    candidate.attached_bus = index
                    candidate.reason = (
                        "accepted: recovered short scan gap to CV bus"
                        if missing_run else "accepted: direct lead reaches CV bus"
                    )
                    return True
                candidate.reason = "rejected: no visible lead before bus"
                return False
        if _line_ink(binary, x, y, lead_direction, thin_width):
            missing_run = 0
            consecutive_ink += 1
            longest_ink_run = max(longest_ink_run, consecutive_ink)
        else:
            missing_run += 1
            consecutive_ink = 0
            allowed_missing_run = (
                max_missing_run
                if longest_ink_run >= thin_width * 3 or orphan_endpoint_candidate
                else normal_missing_run
            )
            if missing_run > allowed_missing_run:
                candidate.reason = "rejected: lead breaks before nearby bus"
                return False
    candidate.reason = "rejected: no nearby bus on lead"
    return False


def _component_axis_spans(
    component: np.ndarray,
    direction: tuple[int, int],
) -> np.ndarray:
    """Measure the perpendicular width from the arrow tip toward its stem."""
    if direction[0] == 0:
        spans = [
            int(np.flatnonzero(row)[-1] - np.flatnonzero(row)[0] + 1)
            if np.any(row) else 0
            for row in component
        ]
        if direction == (0, 1):
            spans.reverse()
        return np.asarray(spans, dtype=np.int32)

    spans = [
        int(np.flatnonzero(column)[-1] - np.flatnonzero(column)[0] + 1)
        if np.any(column) else 0
        for column in component.T
    ]
    if direction == (1, 0):
        spans.reverse()
    return np.asarray(spans, dtype=np.int32)


def _make_outline_load_candidate(
    x: int,
    y: int,
    width: int,
    height: int,
    direction: tuple[int, int],
    area: int,
    thin_width: int,
) -> LoadCandidate:
    """Create a head-only box while retaining the full stem for tracing."""
    long_side, short_side = max(width, height), min(width, height)
    head_depth = max(int(round(short_side * 0.48)), thin_width * 3)
    head_depth = min(head_depth, int(round(long_side * 0.45)))
    extra = max(2, thin_width // 2)
    center_x, center_y = x + width / 2.0, y + height / 2.0
    half_head_width = short_side * 0.44

    if direction == (0, -1):
        head_x, head_y = x, y
        head_width, head_height = width, min(height, head_depth + extra)
        tip = (center_x, y + 1)
        base = (center_x, y + head_depth)
    elif direction == (0, 1):
        head_x = x
        head_y = max(y, y + height - head_depth - extra)
        head_width, head_height = width, min(height, head_depth + extra)
        tip = (center_x, y + height - 1)
        base = (center_x, y + height - head_depth)
    elif direction == (1, 0):
        head_x = max(x, x + width - head_depth - extra)
        head_y = y
        head_width, head_height = min(width, head_depth + extra), height
        tip = (x + width - 1, center_y)
        base = (x + width - head_depth, center_y)
    else:
        head_x, head_y = x, y
        head_width, head_height = min(width, head_depth + extra), height
        tip = (x + 1, center_y)
        base = (x + head_depth, center_y)

    perpendicular = np.asarray((-direction[1], direction[0]), dtype=np.float32)
    base_point = np.asarray(base, dtype=np.float32)
    triangle = np.round(
        np.vstack((
            np.asarray(tip, dtype=np.float32),
            base_point + perpendicular * half_head_width,
            base_point - perpendicular * half_head_width,
        ))
    ).astype(np.int32)
    component_fill = area / max(width * height, 1)
    triangle_score = float(max(0.32, min(0.55, component_fill * 2.0)))
    return LoadCandidate(
        x=head_x,
        y=head_y,
        w=head_width,
        h=head_height,
        tip=tip,
        base=base,
        direction=direction,
        triangle_score=triangle_score,
        reason="candidate: outline arrow",
        core_contour=triangle,
        trace_start_offset=max(1, thin_width // 2),
    )


def outline_arrow_candidates(
    binary: np.ndarray,
    bus_boxes: list[tuple[int, int, int, int]],
    thin_width: int,
) -> list[LoadCandidate]:
    """Find unfilled arrowheads from the bus-connected component geometry.

    Removing the detected bus bars leaves an open arrowhead plus its thin stem
    as one component.  Its width profile is distinctive: the far end widens
    into a triangular head while the bus-facing end stays a narrow stem.  This
    works for outline arrows even when the distance-transform filled-core pass
    sees no interior pixels.
    """
    without_buses = binary.copy()
    bus_margin = max(3, thin_width)
    for x1, y1, x2, y2 in bus_boxes:
        cv2.rectangle(
            without_buses,
            (max(0, x1 - bus_margin), max(0, y1 - bus_margin)),
            (
                min(without_buses.shape[1] - 1, x2 + bus_margin),
                min(without_buses.shape[0] - 1, y2 + bus_margin),
            ),
            0,
            -1,
        )

    count, labels, stats, _ = cv2.connectedComponentsWithStats(
        without_buses, connectivity=8
    )
    minimum_long = max(56, thin_width * 14)
    maximum_long = max(minimum_long + 1, thin_width * 35)
    minimum_short = max(18, thin_width * 4)
    maximum_short = thin_width * 14
    candidates: list[LoadCandidate] = []

    for label in range(1, count):
        x, y, width, height, area = (int(value) for value in stats[label])
        long_side, short_side = max(width, height), min(width, height)
        if not minimum_long <= long_side <= maximum_long:
            continue
        if not minimum_short <= short_side <= maximum_short:
            continue
        if not 1.35 <= long_side / max(short_side, 1) <= 3.20:
            continue
        component = (labels[y:y + height, x:x + width] == label).astype(np.uint8)
        fill_ratio = area / max(width * height, 1)
        if not 0.08 <= fill_ratio <= 0.36:
            continue

        # A genuine unfilled arrow has a small enclosed triangular cavity.
        # Large rectangular/circular holes belong to generators, transformers
        # or annotation artwork and must not enter the load detector.
        component_image = (component * 255).astype(np.uint8)
        contours, hierarchy = cv2.findContours(
            component_image, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE
        )
        holes: list[tuple[float, float, float, float]] = []
        if hierarchy is not None:
            for contour_index, relation in enumerate(hierarchy[0]):
                if relation[3] < 0:
                    continue
                hole_x, hole_y, hole_w, hole_h = cv2.boundingRect(
                    contours[contour_index]
                )
                hole_long = float(max(hole_w, hole_h))
                hole_short = float(min(hole_w, hole_h))
                if hole_long > long_side * 0.32:
                    continue
                if hole_short > short_side * 0.40:
                    continue
                holes.append((
                    hole_x + hole_w / 2.0,
                    hole_y + hole_h / 2.0,
                    hole_w,
                    hole_h,
                ))
        if not holes:
            continue

        vertical_component = height >= width * 1.25
        directions = ((0, -1), (0, 1)) if vertical_component else ((-1, 0), (1, 0))
        scored: list[tuple[float, tuple[int, int]]] = []
        for direction in directions:
            spans = _component_axis_spans(component, direction)
            if not len(spans):
                continue
            head_count = max(6, int(round(len(spans) * 0.42)))
            tail_count = max(6, int(round(len(spans) * 0.30)))
            head_span = int(np.max(spans[:head_count]))
            tail_values = spans[-tail_count:]
            tail_values = tail_values[tail_values > 0]
            tail_span = float(np.median(tail_values)) if len(tail_values) else 0.0
            peak_index = int(np.argmax(spans))
            if head_span < max(tail_span * 2.0, thin_width * 3.0):
                continue
            if head_span < short_side * 0.55:
                continue
            if peak_index > len(spans) * 0.60:
                continue
            hole_near_tip = False
            for hole_x, hole_y, _, _ in holes:
                if direction == (0, -1):
                    hole_distance = hole_y
                elif direction == (0, 1):
                    hole_distance = height - hole_y
                elif direction == (1, 0):
                    hole_distance = width - hole_x
                else:
                    hole_distance = hole_x
                if hole_distance <= long_side * 0.38:
                    hole_near_tip = True
                    break
            if not hole_near_tip:
                continue
            score = (
                head_span / max(tail_span, 1.0)
                - peak_index / max(len(spans), 1)
            )
            scored.append((score, direction))

        if scored:
            _, direction = max(scored, key=lambda item: item[0])
            candidates.append(
                _make_outline_load_candidate(
                    x, y, width, height, direction, area, thin_width
                )
            )
    return candidates


def attach_to_bus_via_pixel_path(
    binary: np.ndarray,
    candidate: LoadCandidate,
    bus_boxes: list[tuple[int, int, int, int]],
    thin_width: int,
    skeleton: np.ndarray | None = None,
    _allow_orientation_correction: bool = True,
) -> bool:
    """Allow a load lead to make a small orthogonal bend before its bus.

    The search starts in the direction opposite the arrowhead and is limited
    by path length and turn count.  It therefore handles a routed feeder bend
    without turning arbitrary text/device pixels into a load connection.
    """
    candidate.attachment_path = None
    if skeleton is None:
        skeleton = bus_cv.skeletonize(binary)
    source_skeleton = np.where(skeleton > 0, 255, 0).astype(np.uint8)
    skeleton = cv2.dilate(
        source_skeleton,
        np.ones((3, 3), np.uint8),
        iterations=1,
    )
    height, width = skeleton.shape
    lead_direction = (-candidate.direction[0], -candidate.direction[1])
    base_x, base_y = candidate.base
    initial_probe = max(6, thin_width * 3)
    probe_x = int(round(base_x + lead_direction[0] * initial_probe))
    probe_y = int(round(base_y + lead_direction[1] * initial_probe))
    # A text contour at the image edge can otherwise launch a U-shaped walk
    # around the border and reach an unrelated bus.  A real load must have at
    # least a short amount of image space on the bus-facing side.
    if not (0 <= probe_x < width and 0 <= probe_y < height):
        return False
    directions = (
        (-1, -1), (0, -1), (1, -1),
        (-1, 0), (1, 0),
        (-1, 1), (0, 1), (1, 1),
    )
    starts: set[tuple[int, int]] = set()
    for distance in range(2, max(8, thin_width * 3) + 1):
        target_x = int(round(base_x + lead_direction[0] * distance))
        target_y = int(round(base_y + lead_direction[1] * distance))
        for y in range(max(0, target_y - 3), min(height, target_y + 4)):
            for x in range(max(0, target_x - 3), min(width, target_x + 4)):
                if skeleton[y, x] > 0:
                    starts.add((x, y))
    if not starts:
        return False

    def inside(point: tuple[int, int], box: tuple[int, int, int, int]) -> bool:
        x, y = point
        x1, y1, x2, y2 = box
        # The skeleton can terminate a few pixels outside the CV rectangle
        # when a vertical bus edge is anti-aliased or slightly detached from
        # the routed lead.  Use the estimated line width as the connection
        # tolerance, not a fixed two-pixel margin.
        margin = max(3, thin_width)
        return x1 - margin <= x <= x2 + margin and y1 - margin <= y <= y2 + margin

    queue: deque[tuple[int, int, int, int, int]] = deque()
    visited: set[tuple[int, int, int, int]] = set()
    parents: dict[
        tuple[int, int, int, int],
        tuple[int, int, int, int] | None,
    ] = {}
    for start_x, start_y in starts:
        delta_x = np.sign(start_x - base_x)
        delta_y = np.sign(start_y - base_y)
        direction_index = min(
            range(len(directions)),
            key=lambda index: (
                directions[index][0] - delta_x
            ) ** 2 + (directions[index][1] - delta_y) ** 2,
        )
        state = (start_x, start_y, direction_index, 0, 0)
        queue.append(state)
        state_key = state[:4]
        visited.add(state_key)
        parents[state_key] = None

    minimum_path = max(12, thin_width * 3)
    maximum_path = max(120, min(height, width) // 2)
    if min(candidate.w, candidate.h) < max(16, thin_width * 4):
        # Tiny candidates are allowed only a short trace.  This preserves
        # small genuine arrows while preventing a glyph from taking a long
        # detour through the drawing to reach an unrelated bus.
        maximum_path = min(maximum_path, max(64, thin_width * 16))
    maximum_turns = 6
    while queue and len(visited) <= 50000:
        x, y, previous_index, turns, steps = queue.popleft()
        if steps >= minimum_path:
            for index, box in enumerate(bus_boxes):
                if inside((x, y), box):
                    candidate.lead_length = steps
                    candidate.attached_bus = index
                    cursor: tuple[int, int, int, int] | None = (
                        x, y, previous_index, turns
                    )
                    traced_path: list[tuple[int, int]] = []
                    while cursor is not None:
                        traced_path.append((cursor[0], cursor[1]))
                        cursor = parents.get(cursor)
                    traced_path.reverse()
                    projected_path = _source_ink_path_within_trace_corridor(
                        source_skeleton,
                        traced_path,
                    )
                    implied_direction = _attachment_implied_arrow_direction(
                        projected_path,
                        thin_width,
                    )
                    if (
                        _allow_orientation_correction
                        and implied_direction is not None
                        and implied_direction != candidate.direction
                    ):
                        _set_candidate_direction(candidate, implied_direction)
                        candidate.attached_bus = None
                        candidate.lead_length = 0
                        candidate.attachment_path = None
                        return attach_to_bus_via_pixel_path(
                            binary,
                            candidate,
                            bus_boxes,
                            thin_width,
                            skeleton=source_skeleton,
                            _allow_orientation_correction=False,
                        )
                    if len(projected_path) >= 2:
                        candidate.attachment_path = projected_path
                    candidate.reason = "accepted: traced lead reaches CV bus"
                    return True
        if steps >= maximum_path:
            continue
        previous = directions[previous_index]
        for direction_index, (dx, dy) in enumerate(directions):
            next_x, next_y = x + dx, y + dy
            if not (0 <= next_x < width and 0 <= next_y < height):
                continue
            if skeleton[next_y, next_x] == 0:
                continue
            if previous[0] * dx + previous[1] * dy < 0:
                continue
            next_turns = turns + int((dx, dy) != previous)
            if next_turns > maximum_turns:
                continue
            key = (next_x, next_y, direction_index, next_turns)
            if key in visited:
                continue
            visited.add(key)
            parents[key] = (x, y, previous_index, turns)
            queue.append(
                (next_x, next_y, direction_index, next_turns, steps + 1)
            )
    return False


def _eligible_for_pixel_path(
    candidate: LoadCandidate,
    thin_width: int,
    binary: np.ndarray | None = None,
) -> bool:
    """Limit bent-lead tracing to visually credible arrowheads.

    The skeleton search is deliberately more permissive than the straight
    lead check.  Applying it to every tiny contour lets a digit stroke wander
    through the diagram and eventually reach a bus.  Real missed loads in the
    tested sheets have a substantially larger arrowhead than those text
    contours, so keep a scale-relative lower bound here.  The outline pass has
    its own geometry and is intentionally not routed through this gate.
    """
    long_side = max(candidate.w, candidate.h)
    short_side = min(candidate.w, candidate.h)
    minimum_long = max(24, thin_width * 6)
    minimum_short = max(16, thin_width * 4)
    if long_side >= minimum_long and short_side >= minimum_short:
        return True
    if long_side < max(16, thin_width * 4):
        return False
    if short_side < max(12, thin_width * 3):
        return False
    if (
        candidate.triangle_score < 0.42
        and not _has_one_sided_terminal_profile(binary, candidate, thin_width)
    ):
        return False
    if binary is not None and _has_enclosed_ink_hole(binary, candidate, thin_width):
        return False
    return True


def _has_one_sided_terminal_profile(
    binary: np.ndarray | None,
    candidate: LoadCandidate,
    thin_width: int,
) -> bool:
    """Check that only the arrow tail continues as an electrical branch.

    This is the circuit-level distinction between a pendant load and a flow
    marker.  The tail must leave the arrowhead as a conductor, while the tip
    must become open circuit after the visible head.  Measurements start
    outside the distance-transform core, so the arrow's own outer pixels do
    not count as a second terminal.
    """
    if binary is None:
        return False
    direction_x, direction_y = candidate.direction
    if (direction_x, direction_y) not in (
        (0, -1), (0, 1), (-1, 0), (1, 0)
    ):
        return False
    height, width = binary.shape[:2]
    radius = max(1, thin_width // 2)

    def has_ink(anchor, direction, distance):
        x = int(round(anchor[0] + direction[0] * distance))
        y = int(round(anchor[1] + direction[1] * distance))
        if not (0 <= x < width and 0 <= y < height):
            return False
        return bool(np.any(binary[
            max(0, y - radius):min(height, y + radius + 1),
            max(0, x - radius):min(width, x + radius + 1),
        ]))

    tail_direction = (-direction_x, -direction_y)
    tail_distances = range(
        max(2, thin_width // 2),
        max(8, thin_width * 3) + 1,
    )
    tail_hits = [
        has_ink(candidate.base, tail_direction, distance)
        for distance in tail_distances
    ]
    if not tail_hits or not all(tail_hits[:max(2, min(len(tail_hits), thin_width))]):
        return False

    axis_extent = candidate.w if direction_x else candidate.h
    tip_start = max(thin_width, int(round(axis_extent * 0.45)))
    tip_distances = range(tip_start, tip_start + max(6, thin_width * 3))
    tip_hits = [
        has_ink(candidate.tip, (direction_x, direction_y), distance)
        for distance in tip_distances
    ]
    # A pendant tip may retain a few anti-aliased edge pixels, but it cannot
    # form a sustained outgoing conductor.
    return sum(tip_hits) < max(2, len(tip_hits) // 3)


def _has_enclosed_ink_hole(
    binary: np.ndarray,
    candidate: LoadCandidate,
    thin_width: int,
) -> bool:
    """Detect a digit-like enclosed cavity inside a tiny fallback candidate."""
    # Include the complete glyph around the thresholded core.  A digit's
    # counter can sit just outside the distance-transform bbox even though it
    # is still part of the same printed character.
    padding = max(8, thin_width * 2)
    x1 = max(0, candidate.x - padding)
    y1 = max(0, candidate.y - padding)
    x2 = min(binary.shape[1], candidate.x + candidate.w + padding + 1)
    y2 = min(binary.shape[0], candidate.y + candidate.h + padding + 1)
    roi = binary[y1:y2, x1:x2]
    contours, hierarchy = cv2.findContours(
        roi, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE
    )
    if hierarchy is None:
        return False
    candidate_x1 = candidate.x - x1
    candidate_y1 = candidate.y - y1
    candidate_x2 = candidate_x1 + candidate.w
    candidate_y2 = candidate_y1 + candidate.h
    minimum_hole_area = max(3.0, float(thin_width * thin_width) * 0.45)
    for index, relation in enumerate(hierarchy[0]):
        if relation[3] < 0:
            continue
        area = abs(float(cv2.contourArea(contours[index])))
        if area < minimum_hole_area:
            continue
        hx, hy, hw, hh = cv2.boundingRect(contours[index])
        center_x = hx + hw / 2.0
        center_y = hy + hh / 2.0
        if (
            candidate_x1 - padding <= center_x <= candidate_x2 + padding
            and candidate_y1 - padding <= center_y <= candidate_y2 + padding
        ):
            return True
    return False


def _safe_small_arrow_candidate(
    binary: np.ndarray,
    candidate: LoadCandidate,
    thin_width: int,
) -> bool:
    """Keep tiny filled arrows while rejecting common numeric-label shapes."""
    # The fallback is intentionally below the normal shape threshold.  Do not
    # allow its lowest-fill contours to become arrows merely because they sit
    # on the same axis as a bus.
    if candidate.triangle_score < 0.30:
        return False
    # Digits such as 4/6 often produce a triangular distance-transform core,
    # but their enclosed counter is not present in a solid arrowhead.
    return not _has_enclosed_ink_hole(binary, candidate, thin_width)


def _deduplicate_accepted_loads(
    candidates: list[LoadCandidate],
) -> list[LoadCandidate]:
    """Keep one result when filled and outline passes see the same head."""
    unique: list[LoadCandidate] = []
    for candidate in candidates:
        center = np.asarray((candidate.x + candidate.w / 2, candidate.y + candidate.h / 2))
        duplicate_index = None
        for index, saved in enumerate(unique):
            saved_center = np.asarray((saved.x + saved.w / 2, saved.y + saved.h / 2))
            threshold = max(candidate.w, candidate.h, saved.w, saved.h) * 0.65
            if float(np.linalg.norm(center - saved_center)) <= threshold:
                duplicate_index = index
                break
        if duplicate_index is None:
            unique.append(candidate)
        elif candidate.lead_length > unique[duplicate_index].lead_length:
            unique[duplicate_index] = candidate
    return unique


def _allow_small_connected_vertical_arrow(
    candidate: LoadCandidate,
    thin_width: int,
) -> bool:
    """Allow a tiny arrow when its physical bus connection is unambiguous.

    A low-resolution downward arrow can rasterize to an almost square core,
    while grounding bars usually form a flat, disconnected pattern.  The
    exception therefore requires all of the evidence that the aspect-ratio
    filter does not provide: a validated bus target, an accepted lead trace,
    a solid-arrow score, and a minimum visible lead length.  It is limited to
    the small-arrow scale so normal ground-bar rejection remains unchanged.
    """
    long_side = max(candidate.w, candidate.h)
    short_side = min(candidate.w, candidate.h)
    return (
        candidate.direction[1] != 0
        and candidate.attached_bus is not None
        and candidate.reason.startswith("accepted:")
        and candidate.triangle_score >= 0.38
        and short_side >= thin_width * 2.0
        and long_side <= max(24, thin_width * 4.0)
        and candidate.lead_length >= thin_width * 4
    )


def _validate_load_candidates(
    binary: np.ndarray,
    candidates: list[LoadCandidate],
    bus_boxes: list[tuple[int, int, int, int]],
    thin_width: int,
) -> tuple[list[LoadCandidate], list[LoadCandidate]]:
    """Keep only arrow candidates with a physical lead to a detected bus."""
    rejected: list[LoadCandidate] = []
    accepted: list[LoadCandidate] = []
    for candidate in candidates:
        if (
            attach_to_bus(binary, candidate, bus_boxes, thin_width)
            and _valid_pendant_load(binary, candidate, thin_width)
        ):
            accepted.append(candidate)
        else:
            rejected.append(candidate)

    # A four-corner arrowhead/stem silhouette can yield both the physical
    # direction and a reverse geometric direction.  The real branch reaches
    # the closest bus; keep just that one result for each arrowhead.
    spatially_unique: list[LoadCandidate] = []
    for candidate in accepted:
        center = np.asarray((candidate.x + candidate.w / 2, candidate.y + candidate.h / 2))
        duplicate_index = None
        for index, saved in enumerate(spatially_unique):
            saved_center = np.asarray((saved.x + saved.w / 2, saved.y + saved.h / 2))
            threshold = max(candidate.w, candidate.h, saved.w, saved.h) * 0.65
            if float(np.linalg.norm(center - saved_center)) <= threshold:
                duplicate_index = index
                break
        if duplicate_index is None:
            spatially_unique.append(candidate)
        elif candidate.lead_length < spatially_unique[duplicate_index].lead_length:
            rejected.append(spatially_unique[duplicate_index])
            spatially_unique[duplicate_index] = candidate
        else:
            rejected.append(candidate)
    accepted = spatially_unique

    # Scanned diagrams do not share one fixed arrow aspect ratio: IEEE24's
    # arrowheads are visibly flatter than the 30/39-bus sheets.  Grounding
    # bars, however, are a separate *much flatter* cluster inside each sheet.
    # Estimate the normal vertical-arrow shape from bus-connected candidates
    # in this image, then remove only clear low-aspect outliers.
    vertical_aspects = [
        candidate.h / max(candidate.w, 1)
        for candidate in accepted
        if candidate.direction[1]
    ]
    if len(vertical_aspects) >= 4:
        minimum_vertical_aspect = max(0.50, float(np.median(vertical_aspects)) * 0.70)
        kept: list[LoadCandidate] = []
        for candidate in accepted:
            aspect = candidate.h / max(candidate.w, 1)
            small_connected_arrow = _allow_small_connected_vertical_arrow(
                candidate, thin_width
            )
            if (
                candidate.direction[1]
                and aspect < minimum_vertical_aspect
                and not small_connected_arrow
            ):
                candidate.reason = "rejected: flat ground-bar pattern"
                rejected.append(candidate)
            else:
                if small_connected_arrow and aspect < minimum_vertical_aspect:
                    candidate.reason = "accepted: small connected vertical arrow"
                kept.append(candidate)
        accepted = kept
    return accepted, rejected


def detect_cv_loads(
    image: np.ndarray,
    bus_records: list[dict] | None = None,
) -> tuple[list[LoadCandidate], list[LoadCandidate], list[tuple[int, int, int, int]]]:
    binary = bus_cv.binarize_and_repair(image)
    thin_width = bus_cv.estimate_thin_line_width(binary)
    bus_boxes = _scaled_bus_boxes(image, bus_records=bus_records)

    # Preserve the stricter detector for normal sheets.  It is the validated
    # path for IEEE24/30/39/14 and avoids treating small text strokes as loads.
    candidates, _ = triangle_candidates(binary, thin_width)
    accepted, rejected = _validate_load_candidates(
        binary, candidates, bus_boxes, thin_width
    )

    # A normal filled arrow can be connected to its bus through one routed
    # bend.  Recover only sufficiently large arrowheads; tiny text candidates
    # stay rejected even if an unconstrained skeleton walk can reach a bus.
    normal_path_accepted: list[LoadCandidate] = []
    normal_remaining_rejected: list[LoadCandidate] = []
    path_skeleton: np.ndarray | None = None
    for candidate in rejected:
        if not _eligible_for_pixel_path(candidate, thin_width, binary):
            normal_remaining_rejected.append(candidate)
            continue
        if not any(
            phrase in candidate.reason
            for phrase in (
                "lead breaks",
                "no nearby bus",
                "no visible lead",
            )
        ):
            normal_remaining_rejected.append(candidate)
            continue
        if path_skeleton is None:
            path_skeleton = bus_cv.skeletonize(binary)
        if attach_to_bus_via_pixel_path(
            binary,
            candidate,
            bus_boxes,
            thin_width,
            skeleton=path_skeleton,
        ):
            candidate.reason = "accepted: traced bent lead reaches CV bus"
            normal_path_accepted.append(candidate)
        else:
            normal_remaining_rejected.append(candidate)

    # TEST20 and similar scans use outline-only arrowheads.  They have no
    # filled core for the distance-transform detector, so inspect the
    # bus-disconnected components for the wider-tip/narrow-stem profile.
    outline_candidates = outline_arrow_candidates(
        binary, bus_boxes, thin_width
    )
    outline_accepted, outline_rejected = _validate_load_candidates(
        binary, outline_candidates, bus_boxes, thin_width
    )
    outline_path_accepted: list[LoadCandidate] = []
    remaining_outline_rejected: list[LoadCandidate] = []
    for candidate in outline_rejected:
        if not candidate.reason.startswith("rejected:"):
            remaining_outline_rejected.append(candidate)
            continue
        if any(
            phrase in candidate.reason
            for phrase in (
                "lead breaks",
                "no nearby bus",
                "no visible lead",
            )
        ):
            if path_skeleton is None:
                path_skeleton = bus_cv.skeletonize(binary)
            if attach_to_bus_via_pixel_path(
                binary,
                candidate,
                bus_boxes,
                thin_width,
                skeleton=path_skeleton,
            ):
                outline_path_accepted.append(candidate)
                continue
        remaining_outline_rejected.append(candidate)

    accepted = _deduplicate_accepted_loads(
        accepted
        + normal_path_accepted
        + outline_accepted
        + outline_path_accepted
    )
    rejected = normal_remaining_rejected + remaining_outline_rejected

    # Some low-resolution sheets (notably TEST1) contain genuine tiny filled
    # arrows that the normal distance threshold cannot retain.  Keep this
    # fallback, but gate it by solid-arrow evidence so labels such as the
    # numbers in TEST16 are not promoted to loads.
    if len(accepted) <= 2 and len(bus_boxes) >= 20:
        fallback_candidates, _ = triangle_candidates(
            binary, thin_width, small_arrow_mode=True
        )
        fallback_accepted, fallback_rejected = _validate_load_candidates(
            binary, fallback_candidates, bus_boxes, thin_width
        )
        safe_fallback = [
            candidate
            for candidate in fallback_accepted
            if _safe_small_arrow_candidate(binary, candidate, thin_width)
            # The fallback intentionally works below the normal arrow-size
            # limit.  Such a tiny core must sit close to its bus; otherwise a
            # digit/short line fragment can follow the skeleton through the
            # network and masquerade as a pendant device.
            and candidate.lead_length <= 50
            and candidate.triangle_score >= 0.38
        ]
        if len(safe_fallback) > len(accepted):
            for candidate in safe_fallback:
                candidate.reason = "accepted: filtered small filled arrow reaches CV bus"
            accepted = _deduplicate_accepted_loads(accepted + safe_fallback)
            safe_ids = {id(candidate) for candidate in safe_fallback}
            for candidate in fallback_accepted:
                if id(candidate) not in safe_ids:
                    candidate.reason = "rejected: small fallback lacks solid-arrow evidence"
                    rejected.append(candidate)
            rejected.extend(fallback_rejected)

    final_accepted: list[LoadCandidate] = []
    for candidate in accepted:
        if _valid_pendant_load(binary, candidate, thin_width):
            final_accepted.append(candidate)
        else:
            rejected.append(candidate)
    accepted = final_accepted

    return accepted, rejected, bus_boxes


def _to_original(candidate: LoadCandidate) -> tuple[int, int, int, int]:
    return tuple(int(round(value / SCALE)) for value in (candidate.x, candidate.y, candidate.w, candidate.h))


def load_triangle_polygon(
    candidate: LoadCandidate,
    image_shape: tuple[int, ...],
    margin: float = 1.0,
) -> np.ndarray:
    """Return the source-pixel triangle used to mask a load from topology.

    The load detector stores geometry at ``SCALE`` resolution.  The polygon
    deliberately covers the filled arrowhead and leaves the lead/base side
    open, so a nearby line is not erased just because the display bbox is
    slightly larger than the printed symbol.
    """
    image_h, image_w = image_shape[:2]
    tip = np.asarray(candidate.tip, dtype=np.float32) / SCALE
    base = np.asarray(candidate.base, dtype=np.float32) / SCALE
    dx, dy = candidate.direction
    direction = np.asarray((dx, dy), dtype=np.float32)
    perpendicular = np.asarray((-dy, dx), dtype=np.float32)
    _, _, core_w, core_h = (
        candidate.x / SCALE,
        candidate.y / SCALE,
        candidate.w / SCALE,
        candidate.h / SCALE,
    )
    half_width = (core_w if dy else core_h) / 2.0 + margin
    tip = tip + direction * margin
    left_base = base + perpendicular * half_width
    right_base = base - perpendicular * half_width
    polygon = np.round(np.vstack((tip, left_base, right_base))).astype(np.int32)
    polygon[:, 0] = np.clip(polygon[:, 0], 0, image_w - 1)
    polygon[:, 1] = np.clip(polygon[:, 1], 0, image_h - 1)
    return polygon


def load_core_mask(
    candidate: LoadCandidate,
    image_shape: tuple[int, ...],
    margin: int = 0,
) -> np.ndarray:
    """Return a mask from the detected load core contour, not its bbox."""
    image_h, image_w = image_shape[:2]
    mask = np.zeros((image_h, image_w), dtype=np.uint8)
    if candidate.core_contour is None or len(candidate.core_contour) < 3:
        polygon = load_triangle_polygon(candidate, image_shape)
        cv2.fillConvexPoly(mask, polygon, 255)
        return mask

    contour = np.round(candidate.core_contour.astype(np.float32) / SCALE).astype(np.int32)
    contour[:, 0] = np.clip(contour[:, 0], 0, image_w - 1)
    contour[:, 1] = np.clip(contour[:, 1], 0, image_h - 1)
    cv2.fillPoly(mask, [contour], 255)
    if margin > 0:
        kernel_size = margin * 2 + 1
        kernel = cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (kernel_size, kernel_size)
        )
        mask = cv2.dilate(mask, kernel, iterations=1)
    return mask


def draw(
    original: np.ndarray,
    accepted: list[LoadCandidate],
    rejected: list[LoadCandidate],
    bus_boxes: list[tuple[int, int, int, int]],
) -> np.ndarray:
    canvas = original.copy()
    for x1, y1, x2, y2 in bus_boxes:
        cv2.rectangle(canvas, (round(x1 / SCALE), round(y1 / SCALE)),
                      (round(x2 / SCALE), round(y2 / SCALE)), (180, 180, 180), 1)
    for candidate in rejected:
        x, y, w, h = _to_original(candidate)
        cv2.rectangle(canvas, (x, y), (x + w, y + h), (0, 0, 200), 1)
    for index, candidate in enumerate(accepted, start=1):
        x, y, w, h = _to_original(candidate)
        cv2.rectangle(canvas, (x, y), (x + w, y + h), (0, 185, 0), 2)
        tip = tuple(int(round(value / SCALE)) for value in candidate.tip)
        base = tuple(int(round(value / SCALE)) for value in candidate.base)
        cv2.arrowedLine(canvas, base, tip, (0, 185, 0), 1, tipLength=0.25)
        cv2.putText(canvas, f"L{index}", (x, max(14, y - 3)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.42, (0, 185, 0), 1, cv2.LINE_AA)
    title = f"CV loads: {len(accepted)} | rejected triangle candidates: {len(rejected)}"
    cv2.rectangle(canvas, (0, 0), (canvas.shape[1], 28), (255, 255, 255), -1)
    cv2.putText(canvas, title, (8, 19), cv2.FONT_HERSHEY_SIMPLEX, 0.50, (0, 0, 0), 1, cv2.LINE_AA)
    return canvas


def save(path: Path, image: np.ndarray) -> None:
    success, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 96])
    if not success:
        raise RuntimeError(path)
    encoded.tofile(str(path))


def main() -> None:
    OUTPUT.mkdir(exist_ok=True)
    for name in INPUT_NAMES:
        source = find_input(name)
        image = read_image(source)
        accepted, rejected, bus_boxes = detect_cv_loads(image)
        folder = OUTPUT / source.stem
        folder.mkdir(exist_ok=True)
        result = draw(image, accepted, rejected, bus_boxes)
        save(folder / "result.jpg", result)
        with (folder / "load_metrics.csv").open("w", newline="", encoding="utf-8-sig") as file:
            writer = csv.DictWriter(file, fieldnames=[
                "load", "x", "y", "width", "height", "direction", "triangle_score",
                "lead_length", "attached_bus", "reason",
            ])
            writer.writeheader()
            for index, candidate in enumerate(accepted + rejected, start=1):
                x, y, w, h = _to_original(candidate)
                writer.writerow({
                    "load": f"L{index}", "x": x, "y": y, "width": w, "height": h,
                    "direction": candidate.direction, "triangle_score": round(candidate.triangle_score, 3),
                    "lead_length": round(candidate.lead_length / SCALE, 1),
                    "attached_bus": candidate.attached_bus if candidate.attached_bus is not None else "",
                    "reason": candidate.reason,
                })
        (folder / "summary.txt").write_text(
            f"source={source.name}\n"
            f"cv_buses={len(bus_boxes)}\n"
            f"accepted_loads={len(accepted)}\n"
            f"rejected_triangle_candidates={len(rejected)}\n",
            encoding="utf-8",
        )
        print(f"{source.name}: loads={len(accepted)}, rejected={len(rejected)}, buses={len(bus_boxes)}")


if __name__ == "__main__":
    main()

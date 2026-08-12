"""OpenCV experiment for detecting arrow/triangle load symbols.

The detector intentionally does not use YOLO.  It accepts a candidate only if
it is a filled triangular arrowhead, has a clear pointing direction, and the
opposite side has a straight lead that reaches a CV-detected bus bar.
"""

from __future__ import annotations

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


def _scaled_bus_boxes(image: np.ndarray) -> list[tuple[int, int, int, int]]:
    boxes = []
    for bus in bus_cv.detect_cv_buses(image):
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
    start_offset = max(3, int(round(max(candidate.w, candidate.h) * 0.36)))
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
        if attach_to_bus(binary, candidate, bus_boxes, thin_width):
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
            if candidate.direction[1] and aspect < minimum_vertical_aspect:
                candidate.reason = "rejected: flat ground-bar pattern"
                rejected.append(candidate)
            else:
                kept.append(candidate)
        accepted = kept
    return accepted, rejected


def detect_cv_loads(image: np.ndarray) -> tuple[list[LoadCandidate], list[LoadCandidate], list[tuple[int, int, int, int]]]:
    binary = bus_cv.binarize_and_repair(image)
    thin_width = bus_cv.estimate_thin_line_width(binary)
    bus_boxes = _scaled_bus_boxes(image)

    # Preserve the stricter detector for normal sheets.  It is the validated
    # path for IEEE24/30/39/14 and avoids treating small text strokes as loads.
    candidates, _ = triangle_candidates(binary, thin_width)
    accepted, rejected = _validate_load_candidates(
        binary, candidates, bus_boxes, thin_width
    )

    # A few scanned one-line diagrams draw every load as a tiny V-shaped
    # arrowhead while keeping buses very thick.  If the normal detector finds
    # almost nothing in a large bus system, retry only this image with the
    # small-arrow parameters; every fallback result must still reach a bus.
    if len(accepted) <= 2 and len(bus_boxes) >= 20:
        fallback_candidates, _ = triangle_candidates(
            binary, thin_width, small_arrow_mode=True
        )
        fallback_accepted, fallback_rejected = _validate_load_candidates(
            binary, fallback_candidates, bus_boxes, thin_width
        )
        if len(fallback_accepted) > len(accepted):
            for candidate in fallback_accepted:
                candidate.reason = "accepted: small-arrow fallback reaches CV bus"
            return fallback_accepted, fallback_rejected, bus_boxes

    return accepted, rejected, bus_boxes


def _to_original(candidate: LoadCandidate) -> tuple[int, int, int, int]:
    return tuple(int(round(value / SCALE)) for value in (candidate.x, candidate.y, candidate.w, candidate.h))


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

"""OpenCV experiment for detecting two common transformer symbols.

This module intentionally does not modify the FastAPI runtime yet. It is an
offline validation step for the two transformer drawings found in the project:

* ``wave``: two opposing rows of repeated U-shaped winding curves, separated
  by a blank gap.
* ``circle_pair``: two similarly sized, overlapping/touching circular
  windings (the outside silhouette resembles a peanut).

Both detectors are structural. They do not use the project's YOLO model or a
crop from a labelled diagram as a template. The experiment writes annotated
comparison images so its behaviour can be reviewed before API integration.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from itertools import combinations
from pathlib import Path
import csv

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "cv_transformer_comparison"
INPUT_NAMES = (
    "IEEE24bus.jpg",
    "24bus.jpg",
    "2026-7-01-8.jpg",
    "2026-7-01-1.jpg",
    "TEST2.jpg",
    "39bus.jpg",
)
ANALYSIS_SCALE = 2
HEADER_HEIGHT = 32


@dataclass
class TransformerDetection:
    """A transformer box in original-image coordinates."""

    x: float
    y: float
    w: float
    h: float
    style: str
    orientation: str
    confidence: float
    detail: str


@dataclass
class _WaveRow:
    x: int
    y: int
    w: int
    h: int
    coverage: float
    variation: float
    turns: int
    density: float
    profile: np.ndarray


def read_image(path: Path) -> np.ndarray:
    """Read paths containing Korean characters on Windows safely."""
    image = cv2.imdecode(np.fromfile(str(path), dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise FileNotFoundError(path)
    return image


def find_input(name: str) -> Path:
    candidates = list(ROOT.rglob(name))
    if not candidates:
        raise FileNotFoundError(name)
    return candidates[0]


def _prepare_binary(image: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Return scaled black-ink binary, gray image, and edge map."""
    scaled = cv2.resize(
        image, None, fx=ANALYSIS_SCALE, fy=ANALYSIS_SCALE,
        interpolation=cv2.INTER_CUBIC,
    )
    gray = cv2.cvtColor(scaled, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    blurred = cv2.GaussianBlur(gray, (5, 5), 1.0)
    edges = cv2.Canny(blurred, 40, 120)
    return binary, gray, edges


def _curve_only_mask(binary: np.ndarray) -> np.ndarray:
    """Remove long horizontal/vertical wiring while retaining winding arcs."""
    short_side = min(binary.shape)
    line_length = max(18, int(round(short_side * 0.022)))
    horizontal = cv2.morphologyEx(
        binary, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (line_length, 1)),
    )
    vertical = cv2.morphologyEx(
        binary, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (1, line_length)),
    )
    return cv2.bitwise_and(binary, cv2.bitwise_not(cv2.bitwise_or(horizontal, vertical)))


def _smoothed_profile(
    mask: np.ndarray, x: int, y: int, w: int, h: int
) -> tuple[float, float, int, float, np.ndarray]:
    """Measure whether a small strip behaves like a repeated curved row."""
    roi = mask[y:y + h, x:x + w]
    if roi.size == 0:
        return 0.0, 0.0, 0, 0.0, np.empty(0, dtype=np.float32)

    centres: list[float] = []
    for column in range(roi.shape[1]):
        points = np.flatnonzero(roi[:, column])
        centres.append(float(np.mean(points)) if len(points) else float("nan"))
    values = np.asarray(centres, dtype=np.float32)
    available = ~np.isnan(values)
    coverage = float(np.mean(available))
    if int(np.count_nonzero(available)) < max(6, w // 5):
        return coverage, 0.0, 0, float(np.mean(roi > 0)), np.empty(0, dtype=np.float32)

    interpolated = np.interp(np.arange(w), np.flatnonzero(available), values[available])
    profile = cv2.GaussianBlur(
        interpolated.astype(np.float32).reshape(1, -1), (0, 0), 2.0
    ).ravel()
    derivative = np.diff(profile)
    derivative[np.abs(derivative) < max(0.04, h * 0.012)] = 0.0
    signs = np.sign(derivative)
    for index in range(1, len(signs)):
        if signs[index] == 0:
            signs[index] = signs[index - 1]
    nonzero = signs[signs != 0]
    turns = int(np.count_nonzero(np.diff(nonzero) != 0)) if len(nonzero) > 1 else 0
    return (
        coverage,
        float(np.ptp(profile)),
        turns,
        float(np.mean(roi > 0)),
        profile,
    )


def _component_wave_rows(curves: np.ndarray) -> list[_WaveRow]:
    """Find one row of three winding lobes after long wires have been removed."""
    image_h, image_w = curves.shape
    short_side = min(image_h, image_w)
    min_segment_width = max(12, int(round(short_side * 0.010)))
    max_segment_width = max(40, int(round(image_w * 0.105)))
    min_height = max(8, int(round(short_side * 0.009)))
    max_height = max(28, int(round(short_side * 0.050)))

    labels_count, _, stats, _ = cv2.connectedComponentsWithStats(curves, connectivity=8)
    segments: list[tuple[int, int, int, int, int]] = []
    for index in range(1, labels_count):
        x, y, w, h, area = (int(value) for value in stats[index])
        if (
            min_segment_width <= w <= max_segment_width
            and min_height <= h <= max_height
            and area >= max(24, min_segment_width * 2)
        ):
            segments.append((x, y, w, h, area))

    vertical_tolerance = max(5, min_height // 2)
    horizontal_gap = max(10, min_segment_width)
    groups: list[list[tuple[int, int, int, int, int]]] = []
    for segment in sorted(segments, key=lambda item: (item[1] + item[3] / 2, item[0])):
        x, y, w, h, _ = segment
        centre_y = y + h / 2
        matching_groups: list[list[tuple[int, int, int, int, int]]] = []
        for group in groups:
            group_centre_y = float(np.mean([item[1] + item[3] / 2 for item in group]))
            left = min(item[0] for item in group)
            right = max(item[0] + item[2] for item in group)
            if (
                abs(centre_y - group_centre_y) <= vertical_tolerance
                and x <= right + horizontal_gap
                and x + w >= left - horizontal_gap
            ):
                matching_groups.append(group)

        if not matching_groups:
            groups.append([segment])
            continue

        # Merge *all* matching groups.  A winding can be split into three
        # components whose middle piece is one pixel lower than the two outer
        # pieces.  A first-match algorithm leaves the far piece stranded when
        # the middle component has not been processed yet.
        merged = [segment]
        for group in matching_groups:
            merged.extend(group)
            groups.remove(group)
        groups.append(merged)

    min_row_width = max(48, int(round(image_w * 0.055)))
    rows: list[_WaveRow] = []
    for group in groups:
        x = min(item[0] for item in group)
        y = min(item[1] for item in group)
        x2 = max(item[0] + item[2] for item in group)
        y2 = max(item[1] + item[3] for item in group)
        w, h = x2 - x, y2 - y
        if w < min_row_width or w > image_w * 0.30:
            continue
        coverage, variation, turns, density, profile = _smoothed_profile(curves, x, y, w, h)
        if (
            coverage < 0.88
            or variation < h * 0.45
            or turns < 5
            or not 0.04 <= density <= 0.42
        ):
            continue
        rows.append(_WaveRow(x, y, w, h, coverage, variation, turns, density, profile))
    return rows


def _best_opposing_row(
    row: _WaveRow,
    curves: np.ndarray,
    binary: np.ndarray,
) -> tuple[int, float, float] | None:
    """Find the second winding row and confirm its empty middle gap."""
    image_h, _ = curves.shape
    start = row.y + row.h + max(2, row.h // 8)
    stop = min(image_h - row.h, row.y + row.h * 4)
    best: tuple[float, int, float] | None = None
    for lower_y in range(start, stop + 1):
        coverage, variation, turns, density, profile = _smoothed_profile(
            curves, row.x, lower_y, row.w, row.h
        )
        if (
            len(profile) == 0
            or coverage < 0.64
            or variation < row.h * 0.40
            or turns < 5
            or not 0.035 <= density <= 0.45
        ):
            continue
        correlation = float(np.corrcoef(row.profile, profile)[0, 1])
        if not np.isfinite(correlation) or correlation > -0.35:
            continue
        gap = binary[
            row.y + row.h:lower_y,
            row.x + int(row.w * 0.15):row.x + int(row.w * 0.85),
        ]
        gap_ink = float(np.mean(gap > 0)) if gap.size else 1.0
        if gap_ink > 0.10:
            continue
        score = (
            coverage * 2.0 + variation / max(row.h, 1)
            + min(turns / 7.0, 1.2) - gap_ink * 2.0
        )
        if best is None or score > best[0]:
            best = (score, lower_y, correlation)
    if best is None:
        return None
    return best[1], best[2], best[0]


def _detect_wave_transformers(binary: np.ndarray) -> list[tuple[int, int, int, int, float, str]]:
    curves = _curve_only_mask(binary)
    candidates: list[tuple[int, int, int, int, float, str]] = []
    for row in _component_wave_rows(curves):
        matched = _best_opposing_row(row, curves, binary)
        if matched is None:
            continue
        lower_y, correlation, score = matched
        margin = max(2, row.h // 8)
        x = max(0, row.x - margin)
        y = max(0, row.y - margin)
        w = row.w + margin * 2
        h = lower_y + row.h - y + margin
        confidence = min(
            0.97,
            0.80 + row.coverage * 0.08 + min(-correlation, 1.0) * 0.07
            + min(score / 8.0, 0.04),
        )
        detail = f"wave rows: coverage={row.coverage:.2f}, corr={correlation:.2f}"
        candidates.append((x, y, w, h, confidence, detail))
    return candidates


def _circle_support(edges: np.ndarray, circle: tuple[float, float, float]) -> float:
    """Fraction of a Hough circle's circumference supported by real edges."""
    x, y, radius = circle
    image_h, image_w = edges.shape
    found = 0
    samples = 72
    for angle in np.linspace(0, 2 * np.pi, samples, endpoint=False):
        px = int(round(x + radius * np.cos(angle)))
        py = int(round(y + radius * np.sin(angle)))
        if np.any(edges[
            max(0, py - 2):min(image_h, py + 3),
            max(0, px - 2):min(image_w, px + 3),
        ]):
            found += 1
    return found / samples


def _binary_circle_support(
    binary: np.ndarray,
    circle: tuple[float, float, float],
) -> float:
    """Measure filled-ink support around a circle's outer ring.

    Hough's edge map is deliberately thin and can lose part of a faint,
    anti-aliased winding.  The thresholded ink mask is a useful second view:
    it tolerates a one- or two-pixel centre/radius error without turning a
    nearby straight wire into a circle by itself.
    """
    x, y, radius = circle
    image_h, image_w = binary.shape
    found = 0
    samples = 144
    for angle in np.linspace(0, 2 * np.pi, samples, endpoint=False):
        supported = False
        for ring_radius in np.linspace(max(1.0, radius - 2.0), radius + 2.0, 5):
            px = int(round(x + ring_radius * np.cos(angle)))
            py = int(round(y + ring_radius * np.sin(angle)))
            if not (0 <= px < image_w and 0 <= py < image_h):
                continue
            if np.any(binary[
                max(0, py - 1):min(image_h, py + 2),
                max(0, px - 1):min(image_w, px + 2),
            ]):
                supported = True
                break
        found += int(supported)
    return found / samples


def _outside_lead_support(
    binary: np.ndarray,
    first: tuple[float, float, float],
    second: tuple[float, float, float],
    orientation: str,
) -> tuple[float, float]:
    """Confirm that a peanut symbol continues as a circuit line on both ends."""
    ordered = sorted(
        (first, second), key=lambda circle: circle[0] if orientation == "horizontal" else circle[1]
    )
    directions = ((-1, 0), (1, 0)) if orientation == "horizontal" else ((0, -1), (0, 1))
    image_h, image_w = binary.shape
    supports: list[float] = []
    for circle, direction in zip(ordered, directions):
        x, y, radius = circle
        present = 0
        tested = 0
        # Hough's centre for a small, overlapping lobe can be several pixels
        # away from the actual wire centre.  Search a narrow perpendicular
        # corridor instead of only a 5x5 patch at one exact row/column.
        transverse_tolerance = max(2, int(round(radius * 0.45)))
        for gap in range(3, 36):
            px = int(round(x + direction[0] * (radius + gap)))
            py = int(round(y + direction[1] * (radius + gap)))
            if not (0 <= px < image_w and 0 <= py < image_h):
                continue
            tested += 1
            if direction[0]:
                patch = binary[
                    max(0, py - transverse_tolerance):min(
                        image_h, py + transverse_tolerance + 1
                    ),
                    max(0, px - 2):min(image_w, px + 3),
                ]
            else:
                patch = binary[
                    max(0, py - 2):min(image_h, py + 3),
                    max(0, px - transverse_tolerance):min(
                        image_w, px + transverse_tolerance + 1
                    ),
                ]
            if np.any(patch):
                present += 1
        supports.append(present / max(tested, 1))
    return supports[0], supports[1]


def _circle_pair_box(
    first: tuple[float, float, float], second: tuple[float, float, float]
) -> tuple[int, int, int, int]:
    x1 = int(np.floor(min(first[0] - first[2], second[0] - second[2])))
    y1 = int(np.floor(min(first[1] - first[2], second[1] - second[2])))
    x2 = int(np.ceil(max(first[0] + first[2], second[0] + second[2])))
    y2 = int(np.ceil(max(first[1] + first[2], second[1] + second[2])))
    return x1, y1, x2 - x1, y2 - y1


def _overlap(box_a: tuple[int, int, int, int], box_b: tuple[int, int, int, int]) -> float:
    ax, ay, aw, ah = box_a
    bx, by, bw, bh = box_b
    left, top = max(ax, bx), max(ay, by)
    right, bottom = min(ax + aw, bx + bw), min(ay + ah, by + bh)
    intersection = max(0, right - left) * max(0, bottom - top)
    union = aw * ah + bw * bh - intersection
    return intersection / union if union else 0.0


def _detect_circle_pair_transformers(
    binary: np.ndarray, gray: np.ndarray, edges: np.ndarray
) -> list[tuple[int, int, int, int, str, float, str]]:
    """Detect two similarly sized, axis-aligned circular windings."""
    short_side = min(gray.shape)
    min_radius = max(5, int(round(short_side * 0.006)))
    max_radius = max(min_radius + 5, int(round(short_side * 0.055)))
    circles = cv2.HoughCircles(
        cv2.GaussianBlur(gray, (5, 5), 1.0),
        cv2.HOUGH_GRADIENT,
        dp=1.0,
        minDist=max(8, int(round(short_side * 0.010))),
        param1=80,
        param2=20,
        minRadius=min_radius,
        maxRadius=max_radius,
    )
    if circles is None:
        return []

    detected = [tuple(float(value) for value in circle) for circle in circles[0]]
    candidates: list[tuple[int, int, int, int, str, float, str]] = []
    for first, second in combinations(detected, 2):
        dx, dy = abs(first[0] - second[0]), abs(first[1] - second[1])
        average_radius = (first[2] + second[2]) / 2.0
        radius_ratio = min(first[2], second[2]) / max(first[2], second[2])
        distance = float(np.hypot(dx, dy))
        if radius_ratio < 0.68 or not 0.72 * average_radius <= distance <= 1.50 * average_radius:
            continue
        if dx >= dy * 2.0:
            orientation = "horizontal"
        elif dy >= dx * 2.0:
            orientation = "vertical"
        else:
            continue

        first_edge_support = _circle_support(edges, first)
        second_edge_support = _circle_support(edges, second)
        first_ink_support = _binary_circle_support(binary, first)
        second_ink_support = _binary_circle_support(binary, second)
        # Keep the stronger of the two measurements.  The edge map is better
        # for clean outlines; the binary ring is better for faint JPEG
        # outlines and slightly inaccurate Hough centres.
        first_support = max(first_edge_support, first_ink_support)
        second_support = max(second_edge_support, second_ink_support)
        # Digits such as ``30`` and the horizontal strokes of a ground symbol
        # can each create a weak Hough circle.  A real winding must have a
        # substantially supported outline on *both* lobes.  The threshold was
        # chosen to keep the smallest confirmed 30-bus winding (0.79) while
        # rejecting those text/ground candidates (0.68--0.76).
        average_support = (first_support + second_support) / 2
        standard_ring_support = min(first_support, second_support) >= 0.78 and average_support >= 0.80
        # A terminal may overlap one winding edge in a dense sheet.  When the
        # companion ring is nearly complete and both outer leads are checked
        # below, allow this single partially obscured ring without admitting
        # two weak text loops.
        one_obscured_but_confirmed = (
            min(first_support, second_support) >= 0.72
            and max(first_support, second_support) >= 0.90
            and average_support >= 0.84
        )
        if not (standard_ring_support or one_obscured_but_confirmed):
            continue
        lead_a, lead_b = _outside_lead_support(binary, first, second, orientation)
        if max(lead_a, lead_b) < 0.80 or min(lead_a, lead_b) < 0.10:
            continue
        x, y, w, h = _circle_pair_box(first, second)
        # A tiny pair may be the two loops inside a digit or an annotation.
        # Work at the analysis scale here: this corresponds to about 20 px in
        # the source image, while the smallest real transformer in the test
        # sheets is still above the limit.
        min_box_short_side = max(40, int(round(short_side * 0.023)))
        if min(w, h) < min_box_short_side:
            continue
        confidence = min(
            0.98,
            0.76 + (first_support + second_support) * 0.10 + min(lead_a, lead_b) * 0.06,
        )
        detail = (
            f"circle supports={first_support:.2f}/{second_support:.2f} "
            f"(edge={first_edge_support:.2f}/{second_edge_support:.2f}), "
            f"lead supports={lead_a:.2f}/{lead_b:.2f}"
        )
        candidates.append((x, y, w, h, orientation, confidence, detail))

    kept: list[tuple[int, int, int, int, str, float, str]] = []
    for candidate in sorted(candidates, key=lambda item: item[5], reverse=True):
        if any(_overlap(candidate[:4], saved[:4]) > 0.30 for saved in kept):
            continue
        kept.append(candidate)
    return kept


def _deduplicate_styles(detections: list[TransformerDetection]) -> list[TransformerDetection]:
    """Avoid duplicate boxes when a scan happens to trigger both styles."""
    kept: list[TransformerDetection] = []
    for detection in sorted(detections, key=lambda item: item.confidence, reverse=True):
        box = (
            int(round((detection.x - detection.w / 2) * ANALYSIS_SCALE)),
            int(round((detection.y - detection.h / 2) * ANALYSIS_SCALE)),
            int(round(detection.w * ANALYSIS_SCALE)),
            int(round(detection.h * ANALYSIS_SCALE)),
        )
        if any(
            _overlap(
                box,
                (
                    int(round((saved.x - saved.w / 2) * ANALYSIS_SCALE)),
                    int(round((saved.y - saved.h / 2) * ANALYSIS_SCALE)),
                    int(round(saved.w * ANALYSIS_SCALE)),
                    int(round(saved.h * ANALYSIS_SCALE)),
                ),
            ) > 0.35
            for saved in kept
        ):
            continue
        kept.append(detection)
    return kept


def detect_cv_transformers(image: np.ndarray) -> list[dict[str, float | str]]:
    """Detect transformers without writing files, using original image scale."""
    binary, gray, edges = _prepare_binary(image)
    detections: list[TransformerDetection] = []
    for x, y, w, h, confidence, detail in _detect_wave_transformers(binary):
        detections.append(TransformerDetection(
            x=(x + w / 2) / ANALYSIS_SCALE,
            y=(y + h / 2) / ANALYSIS_SCALE,
            w=w / ANALYSIS_SCALE,
            h=h / ANALYSIS_SCALE,
            style="wave",
            orientation="vertical",
            confidence=confidence,
            detail=detail,
        ))
    for x, y, w, h, orientation, confidence, detail in _detect_circle_pair_transformers(binary, gray, edges):
        detections.append(TransformerDetection(
            x=(x + w / 2) / ANALYSIS_SCALE,
            y=(y + h / 2) / ANALYSIS_SCALE,
            w=w / ANALYSIS_SCALE,
            h=h / ANALYSIS_SCALE,
            style="circle_pair",
            orientation=orientation,
            confidence=confidence,
            detail=detail,
        ))
    return [asdict(item) for item in _deduplicate_styles(detections)]


def _draw(image: np.ndarray, detections: list[dict[str, float | str]]) -> np.ndarray:
    # A dedicated header margin preserves a transformer located at y=0.
    canvas = cv2.copyMakeBorder(
        image, HEADER_HEIGHT, 0, 0, 0, cv2.BORDER_CONSTANT, value=(255, 255, 255)
    )
    colours = {"wave": (255, 150, 0), "circle_pair": (210, 0, 210)}
    cv2.putText(canvas, f"CV transformers: {len(detections)}", (8, 19), cv2.FONT_HERSHEY_SIMPLEX, 0.52, (0, 0, 0), 1, cv2.LINE_AA)
    for index, detection in enumerate(detections, start=1):
        x = float(detection["x"])
        y = float(detection["y"])
        w = float(detection["w"])
        h = float(detection["h"])
        x1 = int(round(x - w / 2))
        y1 = int(round(y - h / 2)) + HEADER_HEIGHT
        x2 = int(round(x + w / 2))
        y2 = int(round(y + h / 2)) + HEADER_HEIGHT
        style = str(detection["style"])
        colour = colours[style]
        cv2.rectangle(canvas, (x1, y1), (x2, y2), colour, 2)
        label = f"T{index} {style} {float(detection['confidence']):.2f}"
        cv2.putText(canvas, label, (x1, max(16, y1 - 4)), cv2.FONT_HERSHEY_SIMPLEX, 0.46, colour, 1, cv2.LINE_AA)
    return canvas


def _save(path: Path, image: np.ndarray) -> None:
    ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 96])
    if not ok:
        raise RuntimeError(path)
    encoded.tofile(str(path))


def main() -> None:
    OUTPUT.mkdir(exist_ok=True)
    for name in INPUT_NAMES:
        source = find_input(name)
        image = read_image(source)
        detections = detect_cv_transformers(image)
        folder = OUTPUT / source.stem
        folder.mkdir(exist_ok=True)
        result = _draw(image, detections)
        _save(folder / "result.jpg", result)
        source_with_header = cv2.copyMakeBorder(
            image, HEADER_HEIGHT, 0, 0, 0, cv2.BORDER_CONSTANT, value=(255, 255, 255)
        )
        _save(folder / "comparison.jpg", cv2.hconcat([source_with_header, result]))
        with (folder / "transformer_detections.csv").open("w", newline="", encoding="utf-8-sig") as file:
            writer = csv.DictWriter(file, fieldnames=[
                "id", "style", "orientation", "confidence", "x", "y", "w", "h", "detail",
            ])
            writer.writeheader()
            for index, detection in enumerate(detections, start=1):
                writer.writerow({"id": f"T{index}", **detection})
        counts = {
            "wave": sum(detection["style"] == "wave" for detection in detections),
            "circle_pair": sum(detection["style"] == "circle_pair" for detection in detections),
        }
        (folder / "summary.txt").write_text(
            f"source={source.name}\n"
            f"transformers={len(detections)}\n"
            f"wave={counts['wave']}\n"
            f"circle_pair={counts['circle_pair']}\n",
            encoding="utf-8",
        )
        print(f"{source.name}: total={len(detections)}, wave={counts['wave']}, circle_pair={counts['circle_pair']}")


if __name__ == "__main__":
    main()

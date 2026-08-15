"""YOLO detections cross-checked with image-only line topology.

This experimental path never receives filenames or labels.  It only removes
optional isolated load proposals after OpenCV traces the diagram lines.
"""

import io
import os

import cv2
import numpy as np
from PIL import Image
from ultralytics import YOLO

from backend_api.line_recognition.logic.line_topology import extract_line_topology

try:
    from backend_api.line_recognition.logic.port_aware_topology import (
        extract_port_aware_topology,
    )
except ImportError:  # pragma: no cover - supports direct module execution
    from .port_aware_topology import extract_port_aware_topology


CLASS_MAP = {0: "bus", 1: "generator", 2: "load", 3: "transformer"}
MODEL_PATH = os.environ.get("AUTO_TUNE_MODEL_PATH", "backend_api/icon_recognition/models/best.pt")
CONFIDENCE = float(os.environ.get("AUTO_TUNE_CONFIDENCE", "0.25"))
DEFAULT_CLASS_CONFIDENCES = {
    "bus": 0.30,
    "generator": 0.52,
    "load": 0.35,
    "transformer": 0.50,
}
CLASS_CONFIDENCES = {
    key.strip(): float(value)
    for key, value in (item.split("=", 1) for item in os.environ.get("AUTO_TUNE_CLASS_CONFIDENCES", "").split(",") if "=" in item)
}
CLASS_CONFIDENCES = {**DEFAULT_CLASS_CONFIDENCES, **CLASS_CONFIDENCES}
DROP_ISOLATED_LOADS = os.environ.get("AUTO_TUNE_DROP_ISOLATED_LOADS", "1") == "1"
LOAD_TOPOLOGY_BYPASS_CONFIDENCE = float(
    os.environ.get("AUTO_TUNE_LOAD_TOPOLOGY_BYPASS_CONFIDENCE", "0.75")
)
LOW_CONFIDENCE_LOAD_FLOOR = float(
    os.environ.get("AUTO_TUNE_LOW_CONFIDENCE_LOAD_FLOOR", "0.24")
)
LOW_CONFIDENCE_GENERATOR_FLOOR = float(
    os.environ.get("AUTO_TUNE_LOW_CONFIDENCE_GENERATOR_FLOOR", "0.45")
)
LOW_CONFIDENCE_LOAD_MIN_BLUE_RATIO = float(
    os.environ.get("AUTO_TUNE_LOW_CONFIDENCE_LOAD_MIN_BLUE_RATIO", "0.40")
)
LOW_CONFIDENCE_BUS_FLOOR = float(
    os.environ.get("AUTO_TUNE_LOW_CONFIDENCE_BUS_FLOOR", "0.20")
)
LOW_CONFIDENCE_BUS_MIN_ASPECT_RATIO = float(
    os.environ.get("AUTO_TUNE_LOW_CONFIDENCE_BUS_MIN_ASPECT_RATIO", "5.0")
)
LOW_CONFIDENCE_BUS_MIN_WIDTH_RATIO = float(
    os.environ.get("AUTO_TUNE_LOW_CONFIDENCE_BUS_MIN_WIDTH_RATIO", "0.075")
)
BUS_MIN_CONTIGUOUS_LENGTH_RATIO = float(
    os.environ.get("AUTO_TUNE_BUS_MIN_CONTIGUOUS_LENGTH_RATIO", "0.80")
)
BUS_MAX_GLOBAL_SPAN_RATIO = float(
    os.environ.get("AUTO_TUNE_BUS_MAX_GLOBAL_SPAN_RATIO", "0.55")
)
BUS_BORDER_FRAGMENT_ASPECT_RATIO = float(
    os.environ.get("AUTO_TUNE_BUS_BORDER_FRAGMENT_ASPECT_RATIO", "0.10")
)
BUS_BORDER_FRAGMENT_SPAN_RATIO = float(
    os.environ.get("AUTO_TUNE_BUS_BORDER_FRAGMENT_SPAN_RATIO", "0.20")
)
BUS_BORDER_FRAGMENT_MARGIN_RATIO = float(
    os.environ.get("AUTO_TUNE_BUS_BORDER_FRAGMENT_MARGIN_RATIO", "0.02")
)
CROSS_CLASS_CONFLICT_IOU = float(
    os.environ.get("AUTO_TUNE_CROSS_CLASS_CONFLICT_IOU", "0.10")
)
CROSS_CLASS_CONFLICT_IOA = float(
    os.environ.get("AUTO_TUNE_CROSS_CLASS_CONFLICT_IOA", "0.20")
)
LOAD_TOPOLOGY_BYPASS_HOLLOW_SOLIDITY_MAX = float(
    os.environ.get("AUTO_TUNE_LOAD_TOPOLOGY_BYPASS_HOLLOW_SOLIDITY_MAX", "0.50")
)
LOAD_TOPOLOGY_BYPASS_FILLED_SOLIDITY_MIN = float(
    os.environ.get("AUTO_TUNE_LOAD_TOPOLOGY_BYPASS_FILLED_SOLIDITY_MIN", "0.82")
)
LOAD_BBOX_SCALE = float(os.environ.get("AUTO_TUNE_LOAD_BBOX_SCALE", "1.04"))
TOPOLOGY_DILATION_ITERATIONS = int(os.environ.get("AUTO_TUNE_TOPOLOGY_DILATION_ITERATIONS", "12"))
CANVAS_SIZE = int(os.environ.get("AUTO_TUNE_CANVAS_SIZE", "1280"))
MODEL_IMAGE_SIZE = int(os.environ.get("AUTO_TUNE_MODEL_IMAGE_SIZE", "640"))
NON_NATIVE_MODEL_IMAGE_SIZE = int(
    os.environ.get("AUTO_TUNE_NON_NATIVE_MODEL_IMAGE_SIZE", "1280")
)
SECONDARY_MODEL_IMAGE_SIZE = int(
    os.environ.get("AUTO_TUNE_SECONDARY_MODEL_IMAGE_SIZE", "960")
)
USE_SECONDARY_INFERENCE = os.environ.get("AUTO_TUNE_USE_SECONDARY_INFERENCE", "1") == "1"
# Synthetic scale-gate variants are often uniformly or anisotropically
# resized copies of the square training drawings.  Keep the original bytes
# untouched, but allow a canonical-square inference copy so the learned icon
# pixel scale is restored.  Setting this to 0 returns to pure padding/tiling.
USE_CANONICAL_RESIZE_INFERENCE = os.environ.get(
    "AUTO_TUNE_USE_CANONICAL_RESIZE_INFERENCE", "1"
) == "1"
TILE_OVERLAP_RATIO = float(os.environ.get("AUTO_TUNE_TILE_OVERLAP_RATIO", "0.20"))
USE_PORT_AWARE = os.environ.get("AUTO_TUNE_USE_PORT_AWARE", "1") == "1"
USE_CV_LOAD_PORTS = os.environ.get("AUTO_TUNE_USE_CV_LOAD_PORTS", "1") == "1"
USE_CV_BUS_RESCUES = os.environ.get("AUTO_TUNE_USE_CV_BUS_RESCUES", "1") == "1"
MODEL = YOLO(MODEL_PATH)


def _letterbox_to_reference(image: np.ndarray, reference_size: int = CANVAS_SIZE):
    """Place the unmodified image on a square reference canvas.

    This is intentionally *padding*, not a resize.  A 912x900 source therefore
    remains 912x900 pixels and is copied into the centre of a 1280x1280 white
    canvas.  Keeping ``scale == 1`` makes the inverse mapping an exact offset
    subtraction, which is important because all topology work must happen in
    the caller's original coordinate system.

    When a source is larger than the nominal training canvas, the canvas grows
    to the source's long side instead of silently shrinking or distorting the
    drawing.  The caller correspondingly asks YOLO for that canvas size.  This
    explicit branch is slower for very large inputs, but it preserves geometry;
    a future tiled path can be added without changing this transform contract.
    """
    if image is None or image.ndim not in (2, 3):
        raise ValueError("image must be a non-empty 2-D or 3-D array")
    height, width = image.shape[:2]
    if height <= 0 or width <= 0:
        raise ValueError("image must be non-empty")
    canvas_size = max(int(reference_size), int(width), int(height))
    scale = 1.0
    if image.ndim == 2:
        canvas = np.full((canvas_size, canvas_size), 255, dtype=image.dtype)
    else:
        canvas = np.full((canvas_size, canvas_size, image.shape[2]), 255, dtype=image.dtype)
    offset_x = (canvas_size - width) // 2
    offset_y = (canvas_size - height) // 2
    canvas[offset_y:offset_y + height, offset_x:offset_x + width] = image
    return canvas, scale, float(offset_x), float(offset_y)


def _tile_starts(length: int, tile_size: int = CANVAS_SIZE) -> list[int]:
    """Return deterministic overlapping tile origins for a long dimension."""
    if length <= tile_size:
        return [0]
    overlap = min(max(float(TILE_OVERLAP_RATIO), 0.0), 0.75)
    step = max(1, int(round(tile_size * (1.0 - overlap))))
    starts = list(range(0, max(1, length - tile_size + 1), step))
    final_start = max(0, length - tile_size)
    if not starts or starts[-1] != final_start:
        starts.append(final_start)
    return sorted(set(starts))


def _suppress_tiled_duplicates(nodes: list[dict]) -> list[dict]:
    """Merge same-class detections repeated in overlapping inference tiles."""
    if len(nodes) < 2:
        return nodes

    def overlap(first: list[float], second: list[float]) -> tuple[float, float]:
        fx1, fy1 = first[0] - first[2] / 2.0, first[1] - first[3] / 2.0
        fx2, fy2 = first[0] + first[2] / 2.0, first[1] + first[3] / 2.0
        sx1, sy1 = second[0] - second[2] / 2.0, second[1] - second[3] / 2.0
        sx2, sy2 = second[0] + second[2] / 2.0, second[1] + second[3] / 2.0
        intersection = max(0.0, min(fx2, sx2) - max(fx1, sx1)) * max(
            0.0, min(fy2, sy2) - max(fy1, sy1)
        )
        first_area = max(first[2] * first[3], 1e-6)
        second_area = max(second[2] * second[3], 1e-6)
        union = first_area + second_area - intersection
        return intersection / max(union, 1e-6), max(
            intersection / first_area, intersection / second_area
        )

    retained: list[dict] = []
    for node in sorted(nodes, key=lambda item: item["confidence"], reverse=True):
        duplicate = False
        for existing in retained:
            if existing["class"] != node["class"]:
                continue
            iou, ioa = overlap(existing["bbox"], node["bbox"])
            if iou >= 0.35 or ioa >= 0.72:
                duplicate = True
                break
        if not duplicate:
            retained.append(node)
    return retained


def _map_bbox_from_reference(
    bbox: list[float] | tuple[float, float, float, float],
    scale: float,
    offset_x: float,
    offset_y: float,
    image_shape: tuple[int, ...],
) -> list[float]:
    """Map ``[cx, cy, width, height]`` from the reference canvas to the input."""
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    x1 = (centre_x - width / 2.0 - offset_x) / scale
    y1 = (centre_y - height / 2.0 - offset_y) / scale
    x2 = (centre_x + width / 2.0 - offset_x) / scale
    y2 = (centre_y + height / 2.0 - offset_y) / scale
    image_height, image_width = image_shape[:2]
    x1 = min(max(x1, 0.0), float(image_width))
    y1 = min(max(y1, 0.0), float(image_height))
    x2 = min(max(x2, 0.0), float(image_width))
    y2 = min(max(y2, 0.0), float(image_height))
    return [
        (x1 + x2) / 2.0,
        (y1 + y2) / 2.0,
        max(0.0, x2 - x1),
        max(0.0, y2 - y1),
    ]


def _map_point_from_reference(
    point: tuple[float, float] | list[float],
    scale: float,
    offset_x: float,
    offset_y: float,
    image_shape: tuple[int, ...],
) -> tuple[float, float]:
    image_height, image_width = image_shape[:2]
    x = min(max((float(point[0]) - offset_x) / scale, 0.0), float(image_width - 1))
    y = min(max((float(point[1]) - offset_y) / scale, 0.0), float(image_height - 1))
    return x, y


def _map_path_from_reference(
    path: list[tuple[int, int]],
    scale: float,
    offset_x: float,
    offset_y: float,
    image_shape: tuple[int, ...],
) -> list[tuple[int, int]]:
    return [
        tuple(int(round(value)) for value in _map_point_from_reference(
            point, scale, offset_x, offset_y, image_shape
        ))
        for point in path
    ]


def _bbox_to_reference(
    bbox: list[float] | tuple[float, float, float, float],
    scale: float,
    offset_x: float,
    offset_y: float,
) -> list[float]:
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    return [
        centre_x * scale + offset_x,
        centre_y * scale + offset_y,
        width * scale,
        height * scale,
    ]


def _looks_like_transformer_pair(
    image: np.ndarray,
    bbox: list[float] | tuple[float, float, float, float],
) -> bool:
    """Detect the two aligned coil circles used by a Transformer symbol."""
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    short_side = min(width, height)
    if short_side <= 0:
        return False
    padding = max(10, int(round(short_side * 0.40)))
    x1 = max(0, int(round(centre_x - width / 2.0)) - padding)
    y1 = max(0, int(round(centre_y - height / 2.0)) - padding)
    x2 = min(image.shape[1], int(round(centre_x + width / 2.0)) + padding)
    y2 = min(image.shape[0], int(round(centre_y + height / 2.0)) + padding)
    roi = image[y1:y2, x1:x2]
    if roi.size == 0:
        return False
    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 1.2)
    min_radius = max(6, int(round(short_side * 0.20)))
    max_radius = max(min_radius + 2, int(round(short_side * 0.75)))
    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,
        dp=1.0,
        minDist=max(8, int(round(short_side * 0.45))),
        param1=80,
        param2=13,
        minRadius=min_radius,
        maxRadius=max_radius,
    )
    if circles is None:
        return False
    detected = []
    for local_x, local_y, radius in circles[0]:
        global_x, global_y = local_x + x1, local_y + y1
        if (
            abs(global_x - centre_x) <= width * 0.90
            and abs(global_y - centre_y) <= height * 0.90
        ):
            detected.append((float(global_x), float(global_y), float(radius)))
    for index, first in enumerate(detected):
        for second in detected[index + 1:]:
            distance = float(np.hypot(first[0] - second[0], first[1] - second[1]))
            ratio = min(first[2], second[2]) / max(first[2], second[2])
            if distance < max(8.0, short_side * 0.30) or ratio < 0.65:
                continue
            dx, dy = abs(first[0] - second[0]), abs(first[1] - second[1])
            aligned = dy >= dx * 1.35 if height >= width else dx >= dy * 1.35
            if aligned:
                return True
    return False


def _looks_like_generator_circle(
    image: np.ndarray,
    bbox: list[float] | tuple[float, float, float, float],
) -> bool:
    """Detect one circular generator body when YOLO calls it a Transformer."""
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    short_side = min(width, height)
    if short_side <= 0:
        return False
    padding = max(8, int(round(short_side * 0.35)))
    x1 = max(0, int(round(centre_x - width / 2.0)) - padding)
    y1 = max(0, int(round(centre_y - height / 2.0)) - padding)
    x2 = min(image.shape[1], int(round(centre_x + width / 2.0)) + padding)
    y2 = min(image.shape[0], int(round(centre_y + height / 2.0)) + padding)
    roi = image[y1:y2, x1:x2]
    if roi.size == 0:
        return False
    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 1.2)
    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,
        dp=1.0,
        minDist=max(8, int(round(short_side * 0.65))),
        param1=80,
        param2=13,
        minRadius=max(6, int(round(short_side * 0.25))),
        maxRadius=max(10, int(round(short_side * 0.75))),
    )
    if circles is None:
        return False
    inside = []
    for local_x, local_y, radius in circles[0]:
        global_x, global_y = local_x + x1, local_y + y1
        if (
            abs(global_x - centre_x) <= width * 0.65
            and abs(global_y - centre_y) <= height * 0.65
        ):
            inside.append((global_x, global_y, radius))
    if len(inside) != 1:
        return False
    # Require some interior ink (the wave/G) rather than an empty circle.
    _, _, radius = inside[0]
    inner_x1 = max(0, int(round(centre_x - radius * 0.60)))
    inner_y1 = max(0, int(round(centre_y - radius * 0.60)))
    inner_x2 = min(image.shape[1], int(round(centre_x + radius * 0.60)))
    inner_y2 = min(image.shape[0], int(round(centre_y + radius * 0.60)))
    inner = cv2.cvtColor(image[inner_y1:inner_y2, inner_x1:inner_x2], cv2.COLOR_BGR2GRAY)
    return bool(inner.size and 0.015 <= float(np.mean(inner < 180)) <= 0.45)


def _looks_like_numeric_text(
    image: np.ndarray,
    bbox: list[float] | tuple[float, float, float, float],
) -> bool:
    """Recognize compact label glyphs without erasing the source pixels.

    This is intentionally used only as a *candidate veto* and only when the
    component has no validated wire/port contact.  Long Bus bars, circular
    symbols, and arrow-like connected Loads therefore remain eligible.
    """
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    short_side, long_side = min(width, height), max(width, height)
    if short_side <= 0 or long_side <= 0:
        return False
    if long_side / short_side > 3.8:
        return False
    padding = max(3, int(round(short_side * 0.25)))
    x1 = max(0, int(round(centre_x - width / 2.0)) - padding)
    y1 = max(0, int(round(centre_y - height / 2.0)) - padding)
    x2 = min(image.shape[1], int(round(centre_x + width / 2.0)) + padding)
    y2 = min(image.shape[0], int(round(centre_y + height / 2.0)) + padding)
    roi = image[y1:y2, x1:x2]
    if roi.size == 0:
        return False
    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    ink = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)[1]
    dark_ratio = float(np.mean(ink > 0))
    if not 0.04 <= dark_ratio <= 0.72:
        return False
    count, labels, stats, _ = cv2.connectedComponentsWithStats(ink, connectivity=8)
    components = []
    for index in range(1, count):
        component_width = int(stats[index, cv2.CC_STAT_WIDTH])
        component_height = int(stats[index, cv2.CC_STAT_HEIGHT])
        area = int(stats[index, cv2.CC_STAT_AREA])
        if area >= 2:
            components.append((component_width, component_height, area))
    if not components or len(components) > 8:
        return False
    dominant_width, dominant_height, dominant_area = max(components, key=lambda item: item[2])
    roi_height, roi_width = roi.shape[:2]
    if dominant_height < max(3, int(round(roi_height * 0.28))):
        return False
    dominant_density = dominant_area / max(dominant_width * dominant_height, 1)
    # Numeric glyphs occupy a compact component but do not form a long wire.
    return (
        dominant_width <= roi_width * 0.85
        and dominant_height <= roi_height * 0.95
        and 0.08 <= dominant_density <= 0.90
    )


def _has_direct_wire_contact(
    image: np.ndarray,
    bbox: list[float] | tuple[float, float, float, float],
) -> bool:
    """Check for a conductor that actually continues out of a candidate box.

    ``extract_line_topology`` deliberately dilates boxes to tolerate imperfect
    YOLO geometry.  That is useful for tracing, but a nearby digit can then be
    reported as ``connected`` simply because a bus is a few pixels away.  The
    numeric veto uses this stricter, image-only probe: a dark run must begin at
    a box side near its centre and continue outward for several pixels.
    """
    if image is None or image.ndim != 3:
        return False
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    short_side = min(width, height)
    if short_side <= 0:
        return False
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    ink = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)[1] > 0
    image_height, image_width = gray.shape[:2]
    x1 = max(0, int(round(centre_x - width / 2.0)))
    y1 = max(0, int(round(centre_y - height / 2.0)))
    x2 = min(image_width, int(round(centre_x + width / 2.0)))
    y2 = min(image_height, int(round(centre_y + height / 2.0)))
    if x2 <= x1 or y2 <= y1:
        return False

    band = max(2, int(round(short_side * 0.16)))
    probe = max(8, int(round(short_side * 0.85)))
    required = max(4, int(round(short_side * 0.16)))

    def starts_with_run(profile: np.ndarray, edge_index: int, step: int) -> bool:
        """Allow a two-pixel anti-aliased gap, then require a long run."""
        position = edge_index + step
        gap = 0
        run = 0
        for _ in range(probe):
            if position < 0 or position >= profile.size:
                break
            if profile[position]:
                run += 1
                gap = 0
                if run >= required:
                    return True
            else:
                gap += 1
                if run and gap > 2:
                    break
                if not run and gap > 2:
                    return False
            position += step
        return False

    x_centre = int(round(centre_x))
    y_centre = int(round(centre_y))
    half_band_x = max(1, band // 2)
    half_band_y = max(1, band // 2)
    # Top/bottom ports are centred in x; left/right ports are centred in y.
    top_profile = np.any(
        ink[max(0, y1 - probe):y1 + 1,
            max(0, x_centre - half_band_x):min(image_width, x_centre + half_band_x + 1)],
        axis=1,
    )[::-1]
    bottom_profile = np.any(
        ink[y2:min(image_height, y2 + probe),
            max(0, x_centre - half_band_x):min(image_width, x_centre + half_band_x + 1)],
        axis=1,
    )
    left_profile = np.any(
        ink[max(0, y_centre - half_band_y):min(image_height, y_centre + half_band_y + 1),
            max(0, x1 - probe):x1 + 1],
        axis=0,
    )[::-1]
    right_profile = np.any(
        ink[max(0, y_centre - half_band_y):min(image_height, y_centre + half_band_y + 1),
            x2:min(image_width, x2 + probe)],
        axis=0,
    )
    return any(
        starts_with_run(profile, 0, 1)
        for profile in (top_profile, bottom_profile, left_profile, right_profile)
        if profile.size
    )


def suppress_overlapping_bus_fragments(nodes):
    """Merge overlapping fragments of the same collinear Bus.

    Rasterization can split one physical horizontal Bus into multiple
    overlapping detections.  Their geometric union preserves the original
    span, unlike retaining only the higher-confidence fragment.
    """
    retained = []
    for node in sorted(nodes, key=lambda item: item["confidence"], reverse=True):
        if node["class"] != "bus":
            retained.append(node)
            continue
        center_x, center_y, width, height = node["bbox"]
        is_horizontal = width / height >= 5
        duplicate = False
        for existing in retained:
            if existing["class"] != "bus":
                continue
            other_x, other_y, other_width, other_height = existing["bbox"]
            overlap = max(0, min(center_x + width / 2, other_x + other_width / 2)
                          - max(center_x - width / 2, other_x - other_width / 2))
            same_horizontal_line = (
                is_horizontal
                and other_width / other_height >= 5
                and abs(center_y - other_y) <= max(height, other_height) * 1.5
                and overlap / min(width, other_width) >= .35
            )
            if same_horizontal_line:
                left = min(center_x - width / 2, other_x - other_width / 2)
                right = max(center_x + width / 2, other_x + other_width / 2)
                top = min(center_y - height / 2, other_y - other_height / 2)
                bottom = max(center_y + height / 2, other_y + other_height / 2)
                existing["bbox"] = [
                    (left + right) / 2,
                    (top + bottom) / 2,
                    right - left,
                    bottom - top,
                ]
                existing["confidence"] = max(existing["confidence"], node["confidence"])
                duplicate = True
                break
        if not duplicate:
            retained.append(node)
    return retained


def split_bus_predictions_at_ink_gaps(bgr_image, nodes):
    """Split only long horizontal Bus proposals at visible, physical gaps.

    A detector sometimes spans two separate busbars with one wide rectangle.
    The split positions come from blank columns in a horizontal-ink mask, so
    they depend on the drawing itself rather than image-specific coordinates.
    """
    image_height, image_width = bgr_image.shape[:2]
    split_nodes = []
    for node in nodes:
        if node["class"] != "bus":
            split_nodes.append(node)
            continue
        center_x, center_y, width, height = map(float, node["bbox"])
        if height <= 0 or width / height < 5:
            split_nodes.append(node)
            continue
        x1 = max(0, int(np.floor(center_x - width / 2)))
        y1 = max(0, int(np.floor(center_y - height / 2)))
        x2 = min(image_width, int(np.ceil(center_x + width / 2)))
        y2 = min(image_height, int(np.ceil(center_y + height / 2)))
        if x2 - x1 < 30 or y2 <= y1:
            split_nodes.append(node)
            continue
        gray = cv2.cvtColor(bgr_image[y1:y2, x1:x2], cv2.COLOR_BGR2GRAY)
        ink = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)[1]
        kernel_width = max(3, min(15, (x2 - x1) // 8))
        horizontal_ink = cv2.morphologyEx(
            ink, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (kernel_width, 1))
        )
        occupied = np.any(horizontal_ink > 0, axis=0)
        min_gap = max(10, int((x2 - x1) * 0.05))
        gaps, gap_start = [], None
        for offset, is_occupied in enumerate(occupied):
            if not is_occupied and gap_start is None:
                gap_start = offset
            elif is_occupied and gap_start is not None:
                if offset - gap_start >= min_gap:
                    gaps.append((gap_start, offset))
                gap_start = None
        if gap_start is not None and len(occupied) - gap_start >= min_gap:
            gaps.append((gap_start, len(occupied)))
        boundaries = [0] + [(left + right) // 2 for left, right in gaps if left > 0 and right < len(occupied)] + [len(occupied)]
        segments = [(left, right) for left, right in zip(boundaries, boundaries[1:]) if right - left >= 15]
        if len(segments) < 2:
            split_nodes.append(node)
            continue
        for left, right in segments:
            split_node = node.copy()
            split_node["bbox"] = [x1 + (left + right) / 2, center_y, right - left, height]
            split_nodes.append(split_node)
    return split_nodes


def snap_bus_predictions_to_ink(bgr_image, nodes):
    """Align a Bus proposal's long axis to its contiguous raster stroke."""
    image_height, image_width = bgr_image.shape[:2]
    snapped = []
    for node in nodes:
        if node["class"] != "bus":
            snapped.append(node)
            continue
        center_x, center_y, width, height = map(float, node["bbox"])
        horizontal = width >= height
        long_side, short_side = (width, height) if horizontal else (height, width)
        if short_side <= 0 or long_side / short_side < 5:
            snapped.append(node)
            continue
        padding = min(50, max(10, int(long_side * 0.25)))
        if horizontal:
            x1, x2 = max(0, int(center_x - width / 2 - padding)), min(image_width, int(center_x + width / 2 + padding))
            y1, y2 = max(0, int(center_y - max(3, height * 0.7))), min(image_height, int(center_y + max(3, height * 0.7)))
        else:
            x1, x2 = max(0, int(center_x - max(3, width * 0.7))), min(image_width, int(center_x + max(3, width * 0.7)))
            y1, y2 = max(0, int(center_y - height / 2 - padding)), min(image_height, int(center_y + height / 2 + padding))
        roi = bgr_image[y1:y2, x1:x2]
        if roi.size == 0:
            snapped.append(node)
            continue
        ink = cv2.threshold(cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY), 180, 255, cv2.THRESH_BINARY_INV)[1]
        projection = np.any(ink > 0, axis=0 if horizontal else 1)
        center_index = int(round((center_x - x1) if horizontal else (center_y - y1)))
        if not 0 <= center_index < len(projection) or not projection[center_index]:
            snapped.append(node)
            continue
        left = center_index
        while left > 0 and projection[left - 1]:
            left -= 1
        right = center_index
        while right + 1 < len(projection) and projection[right + 1]:
            right += 1
        snapped_length = right - left + 1
        if snapped_length < 15 or not 0.5 <= snapped_length / long_side <= 1.5:
            snapped.append(node)
            continue
        snapped_node = node.copy()
        if horizontal:
            snapped_node["bbox"] = [x1 + (left + right + 1) / 2, center_y, snapped_length, height]
        else:
            snapped_node["bbox"] = [center_x, y1 + (left + right + 1) / 2, width, snapped_length]
        snapped.append(snapped_node)
    return snapped


def bus_contiguous_length_ratio(bgr_image, bbox):
    """Measure how much of a Bus box is covered by one connected ink stroke.

    Dashed borders and text strings can span a long, bus-like rectangle while
    remaining fragmented into short components.  A real bus should contain a
    dominant connected stroke close to the proposal's long-axis length.
    """
    center_x, center_y, width, height = map(float, bbox)
    image_height, image_width = bgr_image.shape[:2]
    x1 = max(0, int(np.floor(center_x - width / 2)))
    y1 = max(0, int(np.floor(center_y - height / 2)))
    x2 = min(image_width, int(np.ceil(center_x + width / 2)))
    y2 = min(image_height, int(np.ceil(center_y + height / 2)))
    if x2 <= x1 or y2 <= y1:
        return 0.0
    crop = bgr_image[y1:y2, x1:x2]
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    ink = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)[1]
    contours, _ = cv2.findContours(ink, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return 0.0
    dominant = max(contours, key=cv2.contourArea)
    _, _, dominant_width, dominant_height = cv2.boundingRect(dominant)
    dominant_length = max(dominant_width, dominant_height)
    proposal_length = max(x2 - x1, y2 - y1)
    return dominant_length / max(proposal_length, 1)


def bus_global_span_ratio(bgr_image, bbox):
    """Measure whether a Bus proposal spans an implausibly large page fraction."""
    _, _, width, height = map(float, bbox)
    image_height, image_width = bgr_image.shape[:2]
    if width >= height:
        return width / max(float(image_width), 1.0)
    return height / max(float(image_height), 1.0)


def suppress_cross_class_conflicts(
    nodes,
    reference_bgr: np.ndarray | None = None,
    preserve_connected_loads: bool = False,
):
    """Keep the stronger prediction when different classes occupy one region."""
    if len(nodes) < 2:
        return nodes
    boxes = []
    for node in nodes:
        center_x, center_y, width, height = map(float, node["bbox"])
        boxes.append((
            center_x - width / 2,
            center_y - height / 2,
            center_x + width / 2,
            center_y + height / 2,
        ))
    keep = [True] * len(nodes)
    for first_index in sorted(range(len(nodes)), key=lambda index: nodes[index]["confidence"], reverse=True):
        if not keep[first_index]:
            continue
        first = boxes[first_index]
        first_area = max(0.0, first[2] - first[0]) * max(0.0, first[3] - first[1])
        for second_index in range(len(nodes)):
            if second_index == first_index or not keep[second_index]:
                continue
            if nodes[first_index]["class"] == nodes[second_index]["class"]:
                continue
            second = boxes[second_index]
            second_area = max(0.0, second[2] - second[0]) * max(0.0, second[3] - second[1])
            intersection = (
                max(0.0, min(first[2], second[2]) - max(first[0], second[0]))
                * max(0.0, min(first[3], second[3]) - max(first[1], second[1]))
            )
            if not intersection or not first_area or not second_area:
                continue
            union = first_area + second_area - intersection
            iou = intersection / max(union, 1e-9)
            ioa = max(intersection / first_area, intersection / second_area)
            if preserve_connected_loads and reference_bgr is not None:
                load_index = None
                if nodes[first_index]["class"] == "load":
                    load_index = first_index
                elif nodes[second_index]["class"] == "load":
                    load_index = second_index
                if load_index is not None:
                    load_node = nodes[load_index]
                    transformer_pair = {
                        nodes[first_index]["class"],
                        nodes[second_index]["class"],
                    } == {"load", "transformer"}
                    if not transformer_pair or load_node["confidence"] >= 0.50:
                        # Keep a physically plausible or strong Load when it
                        # overlaps a Bus/Generator/Transformer box; rasterized
                        # leads often make neighboring boxes touch.
                        continue
                    # A weak Load overlapping a strong Transformer is the
                    # scale-rescue confusion.  Keep the Transformer and drop
                    # only the Load, with the geometric overlap already
                    # established above.
                    if nodes[first_index]["class"] == "transformer":
                        keep[second_index] = False
                    else:
                        keep[first_index] = False
                    continue
            if iou > CROSS_CLASS_CONFLICT_IOU or ioa > CROSS_CLASS_CONFLICT_IOA:
                keep[second_index] = False
    return [node for index, node in enumerate(nodes) if keep[index]]


def has_blue_load_pixels(bgr_image, bbox):
    """Recognize a blue filled Load mark among otherwise weak proposals."""
    center_x, center_y, width, height = map(float, bbox)
    image_height, image_width = bgr_image.shape[:2]
    x1 = max(0, int(center_x - width / 2))
    y1 = max(0, int(center_y - height / 2))
    x2 = min(image_width, int(center_x + width / 2))
    y2 = min(image_height, int(center_y + height / 2))
    if x2 <= x1 or y2 <= y1:
        return False
    hsv = cv2.cvtColor(bgr_image[y1:y2, x1:x2], cv2.COLOR_BGR2HSV)
    blue = (
        (hsv[:, :, 0] >= 95)
        & (hsv[:, :, 0] <= 130)
        & (hsv[:, :, 1] >= 80)
        & (hsv[:, :, 2] >= 60)
    )
    return float(np.mean(blue)) >= LOW_CONFIDENCE_LOAD_MIN_BLUE_RATIO


def has_distinct_load_bypass_shape(bgr_image, bbox):
    """Accept hollow or filled Load marks, but reject mid-density text strokes."""
    center_x, center_y, width, height = map(float, bbox)
    image_height, image_width = bgr_image.shape[:2]
    x1 = max(0, int(center_x - width / 2))
    y1 = max(0, int(center_y - height / 2))
    x2 = min(image_width, int(center_x + width / 2))
    y2 = min(image_height, int(center_y + height / 2))
    if x2 <= x1 or y2 <= y1:
        return False
    gray = cv2.cvtColor(bgr_image[y1:y2, x1:x2], cv2.COLOR_BGR2GRAY)
    _, ink = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)
    contours, _ = cv2.findContours(ink, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return False
    contour = max(contours, key=cv2.contourArea)
    hull_area = cv2.contourArea(cv2.convexHull(contour))
    if hull_area <= 0:
        return False
    solidity = cv2.contourArea(contour) / hull_area
    return (
        solidity <= LOAD_TOPOLOGY_BYPASS_HOLLOW_SOLIDITY_MAX
        or solidity >= LOAD_TOPOLOGY_BYPASS_FILLED_SOLIDITY_MIN
    )


def _contour_generator_candidates(reference_bgr: np.ndarray) -> list[list[float]]:
    """Return conservative circular-generator rescue boxes.

    This is deliberately a *rescue* detector.  YOLO remains authoritative when
    it already places a Generator box; contours are considered only when no
    existing Generator overlaps the candidate.  The hierarchy/ink checks keep
    isolated bus numbers from becoming generators while still handling a
    resized or low-contrast circular ``G`` mark.
    """
    gray = cv2.cvtColor(reference_bgr, cv2.COLOR_BGR2GRAY)
    image_height, image_width = gray.shape[:2]
    minimum_side = max(24.0, min(image_height, image_width) * 0.025)
    maximum_side = min(image_height, image_width) * 0.18
    candidates: list[list[float]] = []
    for threshold in (180, 200, 220):
        mask = cv2.threshold(gray, threshold, 255, cv2.THRESH_BINARY_INV)[1]
        contours, hierarchy = cv2.findContours(
            mask, cv2.RETR_TREE, cv2.CHAIN_APPROX_SIMPLE
        )
        if hierarchy is None:
            continue
        hierarchy = hierarchy[0]
        for index, contour in enumerate(contours):
            x, y, width, height = cv2.boundingRect(contour)
            short_side = min(width, height)
            long_side = max(width, height)
            if short_side < minimum_side or long_side > maximum_side:
                continue
            aspect = long_side / max(short_side, 1)
            if aspect > 1.48:
                continue
            area = float(cv2.contourArea(contour))
            perimeter = float(cv2.arcLength(contour, True))
            circularity = 4.0 * np.pi * area / max(perimeter * perimeter, 1e-6)
            if circularity < 0.80:
                continue
            fill_ratio = area / max(float(width * height), 1.0)
            if not 0.40 <= fill_ratio <= 0.95:
                continue

            # A generator is a ring with ink in its interior.  Requiring a
            # child contour makes a bare digit stroke much less likely to pass.
            child_index = int(hierarchy[index][2])
            if child_index < 0:
                continue
            child_area = float(cv2.contourArea(contours[child_index]))
            child_ratio = child_area / max(area, 1.0)
            if not 0.20 <= child_ratio <= 0.90:
                continue
            crop = gray[y:y + height, x:x + width]
            if crop.size == 0:
                continue
            inner = crop[
                max(0, int(round(height * 0.18))):min(height, int(round(height * 0.82))),
                max(0, int(round(width * 0.18))):min(width, int(round(width * 0.82))),
            ]
            inner_ink = float(np.mean(inner < threshold)) if inner.size else 0.0
            if not 0.025 <= inner_ink <= 0.55:
                continue
            candidates.append([
                x + width / 2.0,
                y + height / 2.0,
                float(width),
                float(height),
            ])

    # One physical ring can appear at all three thresholds (or as its child
    # contour).  Keep a single largest representative for each location.
    unique: list[list[float]] = []
    for candidate in sorted(candidates, key=lambda item: item[2] * item[3], reverse=True):
        if any(
            np.hypot(candidate[0] - saved[0], candidate[1] - saved[1])
            <= max(candidate[2], candidate[3], saved[2], saved[3]) * 0.55
            for saved in unique
        ):
            continue
        unique.append(candidate)
    return unique


def _add_generator_contour_rescues(
    reference_bgr: np.ndarray,
    nodes: list[dict],
    topology_boxes: list[dict],
    scale: float,
    offset_x: float,
    offset_y: float,
    original_shape: tuple[int, ...],
) -> None:
    """Append only non-overlapping, high-quality OpenCV Generator rescues."""
    generator_boxes = [
        node["bbox"] for node in nodes if node.get("class") == "generator"
    ]
    if generator_boxes:
        generator_sizes = [max(float(box[2]), float(box[3])) for box in generator_boxes]
        expected_size = float(np.median(generator_sizes))
    else:
        expected_size = None

    def iou(first: list[float], second: list[float]) -> float:
        fx1, fy1 = first[0] - first[2] / 2.0, first[1] - first[3] / 2.0
        fx2, fy2 = first[0] + first[2] / 2.0, first[1] + first[3] / 2.0
        sx1, sy1 = second[0] - second[2] / 2.0, second[1] - second[3] / 2.0
        sx2, sy2 = second[0] + second[2] / 2.0, second[1] + second[3] / 2.0
        intersection = max(0.0, min(fx2, sx2) - max(fx1, sx1)) * max(0.0, min(fy2, sy2) - max(fy1, sy1))
        union = first[2] * first[3] + second[2] * second[3] - intersection
        return intersection / max(union, 1e-6)

    for candidate in _contour_generator_candidates(reference_bgr):
        mapped = _map_bbox_from_reference(
            candidate, scale, offset_x, offset_y, original_shape
        )
        if mapped[2] <= 0 or mapped[3] <= 0:
            continue
        if expected_size is not None:
            size = max(mapped[2], mapped[3])
            if not 0.45 * expected_size <= size <= 1.8 * expected_size:
                pass
            else:
                continue
        if any(iou(mapped, node["bbox"]) >= 0.25 for node in nodes):
            continue
        component_id = f"generator_cv_{len(nodes)}"
        node = {
            "class": "generator",
            "bbox": mapped,
            "confidence": 0.31,
            "source": "opencv-generator-rescue",
            "_topology_id": component_id,
            "_reference_bbox": candidate,
            "_line_reference_bbox": candidate,
        }
        nodes.append(node)
        x1 = candidate[0] - candidate[2] / 2.0
        y1 = candidate[1] - candidate[3] / 2.0
        x2 = candidate[0] + candidate[2] / 2.0
        y2 = candidate[1] + candidate[3] / 2.0
        topology_boxes.append({
            "id": component_id,
            "bbox": [
                max(0.0, x1), max(0.0, y1),
                min(float(reference_bgr.shape[1]), x2),
                min(float(reference_bgr.shape[0]), y2),
            ],
        })


def _add_cv_bus_rescues(
    reference_bgr: np.ndarray,
    nodes: list[dict],
    topology_boxes: list[dict],
    scale: float,
    offset_x: float,
    offset_y: float,
    original_shape: tuple[int, ...],
) -> None:
    """Add conservative OpenCV bus bars missed by YOLO on non-native inputs.

    The CV detector only proposes long, dark bars and reports their orientation
    and confidence.  It is deliberately a non-native rescue: the exact native
    1280x1280 Train path remains YOLO-only so Train100 cannot drift.  Candidates
    are deduplicated against existing Bus boxes before topology and port checks
    decide whether they are electrically useful.
    """
    if not USE_CV_BUS_RESCUES:
        return
    try:
        from backend_api.cv_bus_refined_experiment import detect_cv_buses
    except (ImportError, ModuleNotFoundError):
        return
    try:
        cv_buses = detect_cv_buses(reference_bgr)
    except Exception:
        return

    def iou(first: list[float], second: list[float]) -> float:
        fx1, fy1 = first[0] - first[2] / 2.0, first[1] - first[3] / 2.0
        fx2, fy2 = first[0] + first[2] / 2.0, first[1] + first[3] / 2.0
        sx1, sy1 = second[0] - second[2] / 2.0, second[1] - second[3] / 2.0
        sx2, sy2 = second[0] + second[2] / 2.0, second[1] + second[3] / 2.0
        intersection = max(0.0, min(fx2, sx2) - max(fx1, sx1)) * max(
            0.0, min(fy2, sy2) - max(fy1, sy1)
        )
        union = first[2] * first[3] + second[2] * second[3] - intersection
        return intersection / max(union, 1e-6)

    existing = [node["bbox"] for node in nodes if node.get("class") == "bus"]
    for candidate in cv_buses:
        width = float(candidate.get("w", 0.0))
        height = float(candidate.get("h", 0.0))
        if width < 4.0 or height < 4.0:
            continue
        reference_bbox = [
            float(candidate.get("x", 0.0)),
            float(candidate.get("y", 0.0)),
            width,
            height,
        ]
        mapped = _map_bbox_from_reference(
            reference_bbox, scale, offset_x, offset_y, original_shape
        )
        if mapped[2] <= 0 or mapped[3] <= 0:
            continue
        if any(iou(mapped, saved) >= 0.25 for saved in existing):
            continue
        confidence = float(candidate.get("confidence", 0.0))
        if confidence < 0.80:
            continue
        component_id = f"bus_cv_{len(nodes)}"
        nodes.append({
            "class": "bus",
            "bbox": mapped,
            "confidence": min(0.55, max(CLASS_CONFIDENCES["bus"], confidence * 0.55)),
            "source": "yolo+opencv-bus-rescue",
            "_topology_id": component_id,
            "_reference_bbox": reference_bbox,
            "_line_reference_bbox": reference_bbox,
            "_transformer_shape": False,
            "_generator_shape": False,
        })
        existing.append(mapped)
        x1 = reference_bbox[0] - reference_bbox[2] / 2.0
        y1 = reference_bbox[1] - reference_bbox[3] / 2.0
        x2 = reference_bbox[0] + reference_bbox[2] / 2.0
        y2 = reference_bbox[1] + reference_bbox[3] / 2.0
        topology_boxes.append({
            "id": component_id,
            "bbox": [
                max(0.0, x1), max(0.0, y1),
                min(float(reference_bgr.shape[1]), x2),
                min(float(reference_bgr.shape[0]), y2),
            ],
        })


def _add_cv_load_rescues(
    reference_bgr: np.ndarray,
    nodes: list[dict],
    topology_boxes: list[dict],
    raw_load_bboxes: list[list[float]] | None = None,
) -> None:
    """Add only CV-confirmed arrow Loads to the canonical scale pass.

    ``cv_load_experiment`` requires a filled arrowhead and a direct lead to a
    detected Bus.  Its raw boxes are intentionally enlarged a little here so
    the complete glyph, rather than only the arrowhead, is scored and traced.
    This function is called only from the non-native canonical-scale rescue;
    the validated native Train path remains unchanged.
    """
    try:
        from backend_api.cv_load_experiment import SCALE as CV_LOAD_SCALE
        from backend_api.cv_load_experiment import detect_cv_loads
    except (ImportError, ModuleNotFoundError):
        return
    try:
        candidates, _, _ = detect_cv_loads(reference_bgr)
    except Exception:
        return

    def iou(first: list[float], second: list[float]) -> float:
        fx1, fy1 = first[0] - first[2] / 2.0, first[1] - first[3] / 2.0
        fx2, fy2 = first[0] + first[2] / 2.0, first[1] + first[3] / 2.0
        sx1, sy1 = second[0] - second[2] / 2.0, second[1] - second[3] / 2.0
        sx2, sy2 = second[0] + second[2] / 2.0, second[1] + second[3] / 2.0
        intersection = max(0.0, min(fx2, sx2) - max(fx1, sx1)) * max(
            0.0, min(fy2, sy2) - max(fy1, sy1)
        )
        union = first[2] * first[3] + second[2] * second[3] - intersection
        return intersection / max(union, 1e-6)

    existing = [node["_reference_bbox"] for node in nodes if node.get("class") == "load"]
    # A weak YOLO proposal may be removed by the confidence gate before this
    # rescue stage.  Keep its geometry as confirmation evidence, without
    # reintroducing the low-confidence detector itself into the output.
    nearby_yolo = list(existing)
    nearby_yolo.extend(raw_load_bboxes or [])
    bbox_scale = float(os.environ.get("AUTO_TUNE_CV_LOAD_RESCUE_BBOX_SCALE", "1.35"))
    for candidate in candidates:
        bbox = [
            (float(candidate.x) + float(candidate.w) / 2.0) / CV_LOAD_SCALE,
            (float(candidate.y) + float(candidate.h) / 2.0) / CV_LOAD_SCALE,
            max(2.0, float(candidate.w) / CV_LOAD_SCALE * bbox_scale),
            max(2.0, float(candidate.h) / CV_LOAD_SCALE * bbox_scale),
        ]
        if bbox[2] <= 0 or bbox[3] <= 0:
            continue
        # CV is a confirmation/rescue stage, not an independent detector.
        # Require a nearby YOLO Load proposal so isolated arrow-like text is
        # never introduced solely by the contour experiment.
        if not any(
            np.hypot(bbox[0] - saved[0], bbox[1] - saved[1])
            <= max(20.0, max(bbox[2], bbox[3], saved[2], saved[3]) * 2.2)
            for saved in nearby_yolo
        ):
            continue
        if any(
            iou(bbox, saved) >= 0.15
            or np.hypot(bbox[0] - saved[0], bbox[1] - saved[1])
            <= max(8.0, max(bbox[2], bbox[3], saved[2], saved[3]) * 0.75)
            for saved in existing
        ):
            continue
        component_id = f"load_cv_{len(nodes)}"
        nodes.append({
            "class": "load",
            "bbox": bbox.copy(),
            "confidence": max(CLASS_CONFIDENCES["load"], 0.52),
            "source": "yolo+opencv-load-rescue",
            "_topology_id": component_id,
            "_reference_bbox": bbox,
            "_line_reference_bbox": bbox,
            "_transformer_shape": False,
            "_generator_shape": False,
            "_canonical_rescue_keep": True,
        })
        existing.append(bbox)
        x1 = bbox[0] - bbox[2] / 2.0
        y1 = bbox[1] - bbox[3] / 2.0
        x2 = bbox[0] + bbox[2] / 2.0
        y2 = bbox[1] + bbox[3] / 2.0
        topology_boxes.append({
            "id": component_id,
            "bbox": [
                max(0.0, x1), max(0.0, y1),
                min(float(reference_bgr.shape[1]), x2),
                min(float(reference_bgr.shape[0]), y2),
            ],
        })


def _cv_load_ports_on_reference(reference_bgr: np.ndarray, nodes: list[dict]) -> dict[str, dict]:
    """Match CV arrow candidates to YOLO Loads for port-aware tracing."""
    if not USE_CV_LOAD_PORTS:
        return {}
    try:
        from backend_api.cv_load_experiment import SCALE as CV_LOAD_SCALE
        from backend_api.cv_load_experiment import detect_cv_loads
    except (ImportError, ModuleNotFoundError):
        return {}
    try:
        cv_loads, _, _ = detect_cv_loads(reference_bgr)
    except Exception:
        return {}
    load_nodes = [node for node in nodes if node.get("class") == "load"]
    ports: dict[str, dict] = {}
    for node in load_nodes:
        node_bbox = node["_reference_bbox"]
        best = None
        best_score = float("inf")
        for candidate in cv_loads:
            candidate_bbox = [
                (candidate.x + candidate.w / 2.0) / CV_LOAD_SCALE,
                (candidate.y + candidate.h / 2.0) / CV_LOAD_SCALE,
                candidate.w / CV_LOAD_SCALE,
                candidate.h / CV_LOAD_SCALE,
            ]
            distance = float(np.hypot(
                candidate_bbox[0] - node_bbox[0], candidate_bbox[1] - node_bbox[1]
            ))
            tolerance = max(12.0, max(node_bbox[2], node_bbox[3]) * 1.25)
            if distance > tolerance:
                continue
            score = distance / max(max(node_bbox[2], node_bbox[3]), 1.0)
            if score < best_score:
                best_score, best = score, candidate
        if best is None:
            continue
        ports[node["_topology_id"]] = {
            "point": [
                float(best.base[0]) / CV_LOAD_SCALE,
                float(best.base[1]) / CV_LOAD_SCALE,
            ],
            "direction": [float(best.direction[0]), float(best.direction[1])],
        }
    return ports


def _predict_raw_detections(
    rgb: np.ndarray,
) -> tuple[np.ndarray, float, float, float, bool, list[tuple[int, str, float, list[float]]]]:
    """Run YOLO with scale-preserving padding, or overlapping native tiles.

    The returned boxes are always expressed in ``reference_rgb`` coordinates.
    For ordinary inputs that reference is the 1280 padded canvas.  For a
    source larger than 1280 it is the original image and each tile prediction
    has already been translated back from its local padded canvas.  The caller
    can therefore perform one consistent unpadding/mapping step before any
    topology work.
    """
    height, width = rgb.shape[:2]
    oversized = width > CANVAS_SIZE or height > CANVAS_SIZE
    if not oversized:
        reference_rgb, scale, offset_x, offset_y = _letterbox_to_reference(rgb)
        confidence_floor = min([
            CONFIDENCE, LOW_CONFIDENCE_BUS_FLOOR, *CLASS_CONFIDENCES.values()
        ])

        def collect(result, start_index: int = 0):
            detections = []
            for index, box in enumerate(result.boxes, start=start_index):
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                detections.append((
                    index,
                    CLASS_MAP[int(box.cls[0])],
                    float(box.conf[0]),
                    [(x1 + x2) / 2.0, (y1 + y2) / 2.0, x2 - x1, y2 - y1],
                ))
            return detections

        primary_size = (
            MODEL_IMAGE_SIZE
            if (width, height) == (CANVAS_SIZE, CANVAS_SIZE)
            else max(MODEL_IMAGE_SIZE, NON_NATIVE_MODEL_IMAGE_SIZE)
        )
        primary = MODEL.predict(
            reference_rgb,
            conf=confidence_floor,
            iou=0.4,
            max_det=300,
            imgsz=primary_size,
            verbose=False,
        )[0]
        detections = collect(primary)
        if (
            USE_SECONDARY_INFERENCE
            and (width, height) != (CANVAS_SIZE, CANVAS_SIZE)
            and SECONDARY_MODEL_IMAGE_SIZE > 0
            and SECONDARY_MODEL_IMAGE_SIZE != primary_size
        ):
            secondary = MODEL.predict(
                reference_rgb,
                conf=confidence_floor,
                iou=0.4,
                max_det=300,
                imgsz=SECONDARY_MODEL_IMAGE_SIZE,
                verbose=False,
            )[0]
            secondary_detections = collect(secondary, start_index=len(detections))

            def overlap(first, second):
                fx1 = first[3][0] - first[3][2] / 2.0
                fy1 = first[3][1] - first[3][3] / 2.0
                fx2 = first[3][0] + first[3][2] / 2.0
                fy2 = first[3][1] + first[3][3] / 2.0
                sx1 = second[3][0] - second[3][2] / 2.0
                sy1 = second[3][1] - second[3][3] / 2.0
                sx2 = second[3][0] + second[3][2] / 2.0
                sy2 = second[3][1] + second[3][3] / 2.0
                intersection = max(0.0, min(fx2, sx2) - max(fx1, sx1)) * max(
                    0.0, min(fy2, sy2) - max(fy1, sy1)
                )
                first_area = max(first[3][2] * first[3][3], 1e-6)
                second_area = max(second[3][2] * second[3][3], 1e-6)
                union = first_area + second_area - intersection
                return intersection / max(union, 1e-6), max(
                    intersection / first_area, intersection / second_area
                )

            merged = sorted(detections + secondary_detections,
                            key=lambda item: item[2], reverse=True)
            detections = []
            for candidate in merged:
                duplicate = False
                for saved in detections:
                    if saved[1] != candidate[1]:
                        continue
                    iou, ioa = overlap(saved, candidate)
                    if iou >= 0.35 or ioa >= 0.72:
                        duplicate = True
                        break
                if not duplicate:
                    detections.append(candidate)
        return reference_rgb, scale, offset_x, offset_y, False, detections

    # A source larger than the training canvas cannot be copied into one 1280
    # square without either shrinking it or clipping it.  Use overlapping
    # 1280px tiles instead.  Each tile is independently padded only at its
    # right/bottom edge, so symbol pixels are never resampled.
    reference_rgb = rgb
    detections: list[tuple[int, str, float, list[float]]] = []
    tile_index = 0
    for tile_y in _tile_starts(height):
        for tile_x in _tile_starts(width):
            crop = rgb[
                tile_y:min(height, tile_y + CANVAS_SIZE),
                tile_x:min(width, tile_x + CANVAS_SIZE),
            ]
            tile_rgb, tile_scale, tile_offset_x, tile_offset_y = _letterbox_to_reference(
                crop, CANVAS_SIZE
            )
            result = MODEL.predict(
                tile_rgb,
                conf=min([CONFIDENCE, LOW_CONFIDENCE_BUS_FLOOR, *CLASS_CONFIDENCES.values()]),
                iou=0.4,
                max_det=300,
                # Keep the model-side image scale identical to training.  The
                # tile pixels themselves remain native (never resized); YOLO's
                # normal 640 preprocessing supplies the same learned scale as
                # the ordinary 1280-canvas path.
                imgsz=MODEL_IMAGE_SIZE,
                verbose=False,
            )[0]
            for box in result.boxes:
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                tile_bbox = [
                    (x1 + x2) / 2.0,
                    (y1 + y2) / 2.0,
                    x2 - x1,
                    y2 - y1,
                ]
                crop_bbox = _map_bbox_from_reference(
                    tile_bbox, tile_scale, tile_offset_x, tile_offset_y, crop.shape
                )
                detections.append((
                    tile_index,
                    CLASS_MAP[int(box.cls[0])],
                    float(box.conf[0]),
                    [
                        crop_bbox[0] + tile_x,
                        crop_bbox[1] + tile_y,
                        crop_bbox[2],
                        crop_bbox[3],
                    ],
                ))
            tile_index += 1
    return reference_rgb, 1.0, 0.0, 0.0, True, detections


def _map_canonical_result_to_original(
    result: dict,
    original_width: int,
    original_height: int,
) -> dict:
    """Undo canonical-square inference scaling for nodes and line paths."""
    scale_x = float(original_width) / float(CANVAS_SIZE)
    scale_y = float(original_height) / float(CANVAS_SIZE)
    for node in result.get("nodes", []):
        centre_x, centre_y, width, height = (float(value) for value in node["bbox"])
        node["bbox"] = [
            centre_x * scale_x,
            centre_y * scale_y,
            width * scale_x,
            height * scale_y,
        ]
    for line in result.get("lines", []):
        line["path"] = [
            (int(round(float(point[0]) * scale_x)), int(round(float(point[1]) * scale_y)))
            for point in line.get("path", [])
        ]
    return result


def analyze_circuit_image_topology_hybrid(
    image_bytes,
    _canonical_scale_rescue: bool = False,
):
    rgb = np.array(Image.open(io.BytesIO(image_bytes)).convert("RGB"))
    original_height, original_width = rgb.shape[:2]
    if (
        USE_CANONICAL_RESIZE_INFERENCE
        and (original_width, original_height) != (CANVAS_SIZE, CANVAS_SIZE)
    ):
        # This is an inference-only copy.  The original image is never
        # overwritten, and every returned coordinate is mapped back after the
        # native square pipeline has completed all topology checks.
        canonical_rgb = cv2.resize(
            rgb,
            (CANVAS_SIZE, CANVAS_SIZE),
            interpolation=cv2.INTER_AREA,
        )
        encoded_ok, encoded = cv2.imencode(
            ".png", cv2.cvtColor(canonical_rgb, cv2.COLOR_RGB2BGR)
        )
        if encoded_ok:
            canonical_result = analyze_circuit_image_topology_hybrid(
                encoded.tobytes(),
                _canonical_scale_rescue=True,
            )
            return _map_canonical_result_to_original(
                canonical_result, original_width, original_height
            )
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    (
        reference_rgb,
        scale,
        offset_x,
        offset_y,
        tiled_input,
        raw_detections,
    ) = _predict_raw_detections(rgb)
    reference_bgr = cv2.cvtColor(reference_rgb, cv2.COLOR_RGB2BGR)
    non_native_input = (
        tiled_input
        or
        tuple(int(value) for value in rgb.shape[:2]) != (CANVAS_SIZE, CANVAS_SIZE)
        or int(reference_rgb.shape[0]) != CANVAS_SIZE
        or int(reference_rgb.shape[1]) != CANVAS_SIZE
        or abs(scale - 1.0) > 1e-3
        or abs(offset_x) > 1.0
        or abs(offset_y) > 1.0
    )
    nodes, topology_boxes = [], []
    for index, (_, class_name, confidence, line_reference_bbox) in enumerate(raw_detections):
        width, height = line_reference_bbox[2], line_reference_bbox[3]
        if class_name == "load":
            width *= LOAD_BBOX_SCALE
            height *= LOAD_BBOX_SCALE
        reference_bbox = [
            line_reference_bbox[0], line_reference_bbox[1], width, height
        ]
        transformer_shape = False
        generator_shape = False
        if non_native_input and class_name in {"generator", "transformer"}:
            original_class_name = class_name
            transformer_shape = _looks_like_transformer_pair(
                reference_bgr, reference_bbox
            )
            generator_shape = _looks_like_generator_circle(
                reference_bgr, reference_bbox
            )
            # A raw Generator prediction is already the safer class decision;
            # a coincidental second Hough circle (often caused by a nearby
            # wire) must not turn it into a Transformer.  Conversely, when
            # YOLO calls a single circular body a Transformer, correct it to
            # Generator.  A true Transformer keeps the two-coil requirement.
            if original_class_name == "transformer":
                if transformer_shape:
                    class_name = "transformer"
                elif generator_shape:
                    class_name = "generator"
            else:
                class_name = "generator"
        bbox = _map_bbox_from_reference(
            reference_bbox, scale, offset_x, offset_y, bgr.shape
        )
        class_confidence = CLASS_CONFIDENCES.get(class_name, CONFIDENCE)
        if confidence < class_confidence:
            is_blue_low_confidence_load = (
                class_name == "load"
                and confidence >= LOW_CONFIDENCE_LOAD_FLOOR
                and has_blue_load_pixels(bgr, bbox)
            )
            canonical_connected_load = (
                _canonical_scale_rescue
                and class_name == "load"
                and confidence >= LOW_CONFIDENCE_LOAD_FLOOR
                and (
                    _has_direct_wire_contact(reference_bgr, reference_bbox)
                    or has_distinct_load_bypass_shape(reference_bgr, reference_bbox)
                )
            )
            canonical_generator_shape = (
                _canonical_scale_rescue
                and class_name == "generator"
                and confidence >= LOW_CONFIDENCE_GENERATOR_FLOOR
                and _looks_like_generator_circle(reference_bgr, reference_bbox)
            )
            is_linear_low_confidence_bus = (
                class_name == "bus"
                and confidence >= LOW_CONFIDENCE_BUS_FLOOR
                and height > 0
                and max(reference_bbox[2] / max(reference_bbox[3], 1e-6), reference_bbox[3] / max(reference_bbox[2], 1e-6)) >= LOW_CONFIDENCE_BUS_MIN_ASPECT_RATIO
                and max(bbox[2], bbox[3]) >= max(bgr.shape[:2]) * LOW_CONFIDENCE_BUS_MIN_WIDTH_RATIO
            )
            if (
                not is_blue_low_confidence_load
                and not canonical_connected_load
                and not canonical_generator_shape
                and not is_linear_low_confidence_bus
            ):
                continue
        if (
            _canonical_scale_rescue
            and class_name == "load"
            and confidence < 0.35
            and not _has_direct_wire_contact(reference_bgr, reference_bbox)
        ):
            # Very weak, lead-less Load proposals are text/fragment artefacts;
            # genuine small Loads in the scale matrix retain a direct lead.
            continue
        if (
            _canonical_scale_rescue
            and class_name == "load"
            and not _has_direct_wire_contact(reference_bgr, reference_bbox)
            and not has_distinct_load_bypass_shape(reference_bgr, reference_bbox)
            and _looks_like_numeric_text(reference_bgr, reference_bbox)
        ):
            # A compact numeric/text glyph with neither an electrical lead
            # nor a load-specific arrow shape is not a physical component.
            continue
        node = {
            "class": class_name,
            "bbox": bbox,
            "confidence": confidence,
            "source": "yolo+topology",
            "_topology_id": f"{class_name}_{index}",
            "_reference_bbox": reference_bbox,
            "_line_reference_bbox": line_reference_bbox,
            "_transformer_shape": transformer_shape,
            "_generator_shape": generator_shape,
        }
        nodes.append(node)
        topology_boxes.append({
            "id": node["_topology_id"],
            "bbox": [
                reference_bbox[0] - reference_bbox[2] / 2.0,
                reference_bbox[1] - reference_bbox[3] / 2.0,
                reference_bbox[0] + reference_bbox[2] / 2.0,
                reference_bbox[1] + reference_bbox[3] / 2.0,
            ],
        })

    if tiled_input:
        nodes = _suppress_tiled_duplicates(nodes)

    # Generator contours are a guarded rescue only.  The native 1280x1280
    # training path stays YOLO-only; contour rescue is needed when a caller's
    # input had to be uniformly up/down-scaled into the reference canvas.
    if non_native_input:
        _add_generator_contour_rescues(
            reference_bgr, nodes, topology_boxes,
            scale, offset_x, offset_y, bgr.shape,
        )
        _add_cv_bus_rescues(
            reference_bgr, nodes, topology_boxes,
            scale, offset_x, offset_y, bgr.shape,
        )
    if _canonical_scale_rescue:
        _add_cv_load_rescues(
            reference_bgr,
            nodes,
            topology_boxes,
            raw_load_bboxes=[
                list(detection[3])
                for detection in raw_detections
                if detection[1] == "load"
            ],
        )

    nodes = suppress_cross_class_conflicts(
        nodes,
        reference_bgr=reference_bgr,
        preserve_connected_loads=_canonical_scale_rescue,
    )
    topology_ids = {node["_topology_id"] for node in nodes}
    topology_boxes = [box for box in topology_boxes if box["id"] in topology_ids]
    line_boxes = []
    for node in nodes:
        reference_bbox = node.get("_line_reference_bbox", node["_reference_bbox"])
        mapped_bbox = _map_bbox_from_reference(
            reference_bbox, scale, offset_x, offset_y, bgr.shape
        )
        line_boxes.append({
            "id": node["_topology_id"],
            "bbox": [
                mapped_bbox[0] - mapped_bbox[2] / 2.0,
                mapped_bbox[1] - mapped_bbox[3] / 2.0,
                mapped_bbox[0] + mapped_bbox[2] / 2.0,
                mapped_bbox[1] + mapped_bbox[3] / 2.0,
            ],
        })
    connections, topology_debug = extract_line_topology(
        bgr, line_boxes, dilation_iters=TOPOLOGY_DILATION_ITERATIONS
    )
    linked_ids = {node_id for pair in connections for node_id in pair}
    wire_contact_ids = {
        node_id for node_id, line_ids in (topology_debug or {}).get("box_to_lines", {}).items()
        if line_ids
    }
    direct_contact_ids = {
        node["_topology_id"]
        for node in nodes
        if _has_direct_wire_contact(reference_bgr, node["_reference_bbox"])
    }
    if _canonical_scale_rescue:
        direct_contact_ids.update(
            node["_topology_id"]
            for node in nodes
            if _has_direct_wire_contact(
                reference_bgr,
                [
                    node["_reference_bbox"][0],
                    node["_reference_bbox"][1],
                    node["_reference_bbox"][2] * 2.0,
                    node["_reference_bbox"][3] * 2.0,
                ],
            )
        )

    port_lines = []
    port_debug = None
    if USE_PORT_AWARE and nodes:
        port_components = []
        for node in nodes:
            reference_bbox = _bbox_to_reference(
                node["bbox"], scale, offset_x, offset_y
            )
            node["_reference_bbox"] = reference_bbox
            port_components.append({
                "id": node["_topology_id"],
                "class": node["class"],
                "bbox": reference_bbox,
            })
        load_ports = (
            _cv_load_ports_on_reference(reference_bgr, nodes)
            if non_native_input else {}
        )
        try:
            port_lines, port_debug = extract_port_aware_topology(
                reference_bgr,
                port_components,
                load_ports=load_ports,
                remove_numeric_text=True,
            )
        except (TypeError, ValueError, cv2.error):
            # Port-aware tracing is an augmentation.  A malformed low-level
            # contour must never make the detector endpoint unavailable.
            port_lines, port_debug = [], None
        # Keep the validated native path bit-for-bit stable.  On a resized or
        # padded input, port-aware contacts become the additional evidence that
        # recovers vertical/branching connections lost by the old mask.
        if non_native_input:
            linked_ids.update(
                component_id
                for line in port_lines
                for component_id in line.get("connected_to", [])
            )
            port_contact_ids = set((port_debug or {}).get("endpoint_to_component", {}).values())
            wire_contact_ids.update(port_contact_ids)
    if non_native_input:
        filtered_nodes = []
        for node in nodes:
            component_id = node["_topology_id"]
            topology_connected = component_id in linked_ids or component_id in wire_contact_ids
            direct_wire_contact = component_id in direct_contact_ids
            connected = topology_connected or direct_wire_contact
            # A circular Generator body has a ring plus an interior wave/G;
            # the compact-glyph heuristic quite reasonably sees that interior
            # ink, so shape evidence takes precedence for Generator candidates.
            genuine_generator_shape = (
                node["class"] == "generator"
                and node.get("_generator_shape", False)
            )
            # A Transformer must have an electrical connection.  A compact,
            # disconnected glyph is overwhelmingly a bus-number label (the
            # common 6/8 false positive).  Preserve connected ambiguous shapes.
            if (
                node["class"] == "transformer"
                and not connected
                and _looks_like_numeric_text(reference_bgr, node["_reference_bbox"])
            ):
                continue
            # Apply the same no-box policy to other compact numeric labels, but
            # never veto a candidate that has a physical line/port contact.
            if (
                not connected
                and node["class"] in {"bus", "generator", "load"}
                and not genuine_generator_shape
                and _looks_like_numeric_text(reference_bgr, node["_reference_bbox"])
            ):
                continue
            filtered_nodes.append(node)
        nodes = filtered_nodes
    if DROP_ISOLATED_LOADS:
        nodes = [
            node for node in nodes
            if node["class"] != "load"
            # Topology is a useful veto for weak proposals, but line extraction
            # can erase a load lead while masking its box.  A high-confidence
            # image detection is retained only for the hollow and filled Load
            # shape families, not mid-density text fragments, when topology is
            # incomplete.
            or (
                node["confidence"] >= LOAD_TOPOLOGY_BYPASS_CONFIDENCE
                and has_distinct_load_bypass_shape(bgr, node["bbox"])
            )
            or node["_topology_id"] in linked_ids
            or node["_topology_id"] in wire_contact_ids
            or node["_topology_id"] in direct_contact_ids
            or node.get("_canonical_rescue_keep", False)
        ]
    if _canonical_scale_rescue:
        # A right-edge numeric glyph can look like a high-confidence Load even
        # though it has no electrical lead.  Limit this veto to the extreme
        # border and leave connected edge Loads untouched.
        nodes = [
            node for node in nodes
            if not (
                node["class"] == "load"
                and node["bbox"][0] >= bgr.shape[1] * 0.98
                and node["_topology_id"] not in direct_contact_ids
                and _looks_like_numeric_text(
                    reference_bgr,
                    node.get("_reference_bbox", node["bbox"]),
                )
            )
        ]
    nodes = [
        node for node in nodes
        if (
            node["class"] != "bus"
            or node["confidence"] >= CLASS_CONFIDENCES["bus"]
            or node["_topology_id"] in linked_ids
        )
    ]
    nodes = [
        node for node in nodes
        if (
            node["class"] != "bus"
            or bus_contiguous_length_ratio(bgr, node["bbox"])
            >= BUS_MIN_CONTIGUOUS_LENGTH_RATIO
        )
    ]
    nodes = [
        node for node in nodes
        if (
            node["class"] != "bus"
            or bus_global_span_ratio(bgr, node["bbox"])
            <= BUS_MAX_GLOBAL_SPAN_RATIO
        )
    ]
    # A page border or crop edge can look like a very long, hairline Bus.
    # Real Bus symbols are substantially thicker; reject only the extreme
    # border fragment geometry so legitimate edge-connected Buses remain.
    image_height, image_width = bgr.shape[:2]
    nodes = [
        node for node in nodes
        if (
            node["class"] != "bus"
            or not (
                max(float(node["bbox"][2]), float(node["bbox"][3])) >
                max(image_width, image_height) * BUS_BORDER_FRAGMENT_SPAN_RATIO
                and min(float(node["bbox"][2]), float(node["bbox"][3])) /
                max(float(node["bbox"][2]), float(node["bbox"][3]), 1e-6) <
                BUS_BORDER_FRAGMENT_ASPECT_RATIO
                and (
                    float(node["bbox"][0]) <= image_width * BUS_BORDER_FRAGMENT_MARGIN_RATIO
                    or float(node["bbox"][0]) >= image_width * (1.0 - BUS_BORDER_FRAGMENT_MARGIN_RATIO)
                    or float(node["bbox"][1]) <= image_height * BUS_BORDER_FRAGMENT_MARGIN_RATIO
                    or float(node["bbox"][1]) >= image_height * (1.0 - BUS_BORDER_FRAGMENT_MARGIN_RATIO)
                )
            )
        )
    ]
    nodes = suppress_overlapping_bus_fragments(nodes)
    nodes = split_bus_predictions_at_ink_gaps(bgr, nodes)
    nodes = snap_bus_predictions_to_ink(bgr, nodes)
    remaining_ids = {node["_topology_id"] for node in nodes}
    output_lines = []
    for index, line in enumerate(port_lines, start=1):
        connected_to = [
            component_id
            for component_id in line.get("connected_to", [])
            if component_id in remaining_ids
        ]
        if len(connected_to) != 2:
            continue
        output_lines.append({
            "line_id": f"L{index}",
            "connected_to": connected_to,
            "path": _map_path_from_reference(
                line.get("path", []), scale, offset_x, offset_y, bgr.shape
            ),
            "source_port": line.get("source_port"),
            "target_port": line.get("target_port"),
            "trace_method": "port-aware",
        })
    existing_pairs = {tuple(sorted(line["connected_to"])) for line in output_lines}
    for pair in connections:
        pair = list(pair)
        if len(pair) != 2 or any(component_id not in remaining_ids for component_id in pair):
            continue
        if tuple(sorted(pair)) in existing_pairs:
            continue
        output_lines.append({
            "line_id": f"L{len(output_lines) + 1}",
            "connected_to": pair,
            "path": [],
            "trace_method": "component-topology",
        })
    for node in nodes:
        node.pop("_topology_id", None)
        node.pop("_reference_bbox", None)
        node.pop("_line_reference_bbox", None)
        node.pop("_transformer_shape", None)
        node.pop("_generator_shape", None)
        node.pop("_canonical_rescue_keep", None)
    return {"status": "success", "nodes": nodes, "lines": output_lines}

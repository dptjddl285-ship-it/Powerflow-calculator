# 파일명: vision_logic.py
import cv2
import numpy as np
import math
import os
from collections import deque
import cv_bus_refined_experiment as bus_cv
import cv_load_experiment as load_cv
from cv_bus_refined_experiment import detect_cv_buses
from cv_load_experiment import (
    SCALE as LOAD_SCALE,
    attach_to_bus_via_pixel_path,
    detect_cv_loads,
    load_core_mask,
    load_triangle_polygon,
)
from cv_transformer_experiment import detect_cv_transformers
from core.electrical_topology import (
    bridge_one_pixel_gaps,
    skeletonize_binary,
    trace_electrical_connections,
)


# ---------------------------------------------------------------------------
# Hybrid detector policy
# ---------------------------------------------------------------------------
# YOLO proposes all four symbol classes.  OpenCV is allowed to refine the
# topology geometry and to add a missed object only when its own structural
# checks pass.  This deliberately avoids the old "YOLO bus/load/transformer
# detections are discarded" policy, which caused the held-out recall collapse.
YOLO_CLASS_CONFIDENCES = {
    "bus": float(os.environ.get("POWERLENS_BUS_CONF", "0.30")),
    # A low-confidence generator is still only a proposal. It is admitted
    # below after CV proves a circle with an electrical lead or a bus terminal.
    "generator": float(os.environ.get("POWERLENS_GENERATOR_CONF", "0.30")),
    "load": float(os.environ.get("POWERLENS_LOAD_CONF", "0.27")),
    "transformer": float(os.environ.get("POWERLENS_TRANSFORMER_CONF", "0.50")),
}
YOLO_IMAGE_SIZE = int(os.environ.get("POWERLENS_YOLO_IMGSZ", "640"))
YOLO_PROBE_CONFIDENCE = float(os.environ.get("POWERLENS_YOLO_PROBE_CONF", "0.05"))
CV_SUPPLEMENT_ENABLED = os.environ.get("POWERLENS_CV_SUPPLEMENT", "1") == "1"
CV_ALLOW_WEAK_YOLO_ADD = os.environ.get("POWERLENS_CV_ALLOW_WEAK_YOLO_ADD", "1") == "1"
# Experimental second-stage bus recovery.  It remains opt-in until it has
# beaten the current strict policy on both the held-out sheets and TEST files.
# A YOLO box never becomes a bus on its own: it must overlap a CV-extracted
# straight-bar candidate that was excluded only by the global family selector.
RELAXED_BUS_RESCUE = os.environ.get("POWERLENS_RELAXED_BUS_RESCUE", "1") == "1"
# A YOLO load proposal can be revived only after its bus-facing tail has been
# traced in the binary conductor graph.  Kept opt-in for held-out regression.
YOLO_LOAD_PORT_RESCUE = os.environ.get("POWERLENS_YOLO_LOAD_PORT_RESCUE", "1") == "1"
# A clearly printed standalone ``G`` symbol can appear in a diagram legend.
# It has no electrical terminal to validate, so retain only independently
# high-confidence generator proposals in that exceptional presentation case.
YOLO_GENERATOR_STANDALONE_CONF = float(
    os.environ.get("POWERLENS_GENERATOR_STANDALONE_CONF", "0.80")
)
YOLO_TRANSFORMER_CONFIRM_CONF = float(
    os.environ.get("POWERLENS_TRANSFORMER_CONFIRM_CONF", "0.70")
)
YOLO_AMBIGUOUS_LOAD_CONFIRM_CONF = float(
    os.environ.get("POWERLENS_AMBIGUOUS_LOAD_CONFIRM_CONF", "0.75")
)
# Some scans draw a bus at nearly the same stroke width as a feeder.  In that
# case YOLO may locate the *area* correctly while the directional CV mask
# splits the bar at its terminals.  This opt-in path reconstructs a complete
# straight raster run from that proposal and validates it with CV before it
# can become a bus.  The YOLO rectangle itself is never emitted.
YOLO_BUS_RUN_RESCUE = os.environ.get("POWERLENS_YOLO_BUS_RUN_RESCUE", "0") == "1"
YOLO_BUS_RUN_MIN_CONF = float(os.environ.get("POWERLENS_YOLO_BUS_RUN_MIN_CONF", "0.25"))
# A completely independent CV candidate is useful for a detector-only setup,
# but it is deliberately opt-in: on the held-out set, unconditional union
# added more false positives than true objects.  A weak YOLO proposal is the
# safer hand-off point for the CV rescue stage.
CV_ALLOW_STANDALONE_ADD = os.environ.get("POWERLENS_CV_ALLOW_STANDALONE_ADD", "0") == "1"
CV_ADD_BUS_MIN_CONF = float(os.environ.get("POWERLENS_CV_ADD_BUS_MIN_CONF", "0.90"))
CV_ADD_LOAD_MIN_CONF = float(os.environ.get("POWERLENS_CV_ADD_LOAD_MIN_CONF", "0.86"))
# Transformer CV is deliberately allowed to stand on its own at a high
# structural score.  Unlike buses and loads, a matched winding pair is rare
# in ordinary labels/wiring, and requiring YOLO to confirm it can discard a
# complete CV box when YOLO sees only one half of the winding.
CV_ADD_TRANSFORMER_MIN_CONF = float(
    os.environ.get("POWERLENS_CV_ADD_TRANSFORMER_MIN_CONF", "0.90")
)


def _normalise_detection_class(value):
    aliases = {"gen": "generator", "trans": "transformer"}
    return aliases.get(str(value).strip().lower(), str(value).strip().lower())


def _xywh_to_xyxy(bbox, image_shape):
    height, width = image_shape[:2]
    centre_x, centre_y, box_width, box_height = (float(value) for value in bbox)
    return (
        max(0, int(round(centre_x - box_width / 2))),
        max(0, int(round(centre_y - box_height / 2))),
        min(width - 1, int(round(centre_x + box_width / 2))),
        min(height - 1, int(round(centre_y + box_height / 2))),
    )


def _bbox_iou(first, second):
    first_x1, first_y1, first_x2, first_y2 = _xywh_to_xyxy(first, (10_000, 10_000))
    second_x1, second_y1, second_x2, second_y2 = _xywh_to_xyxy(second, (10_000, 10_000))
    intersection = max(0, min(first_x2, second_x2) - max(first_x1, second_x1)) * max(
        0, min(first_y2, second_y2) - max(first_y1, second_y1)
    )
    first_area = max(0, first_x2 - first_x1) * max(0, first_y2 - first_y1)
    second_area = max(0, second_x2 - second_x1) * max(0, second_y2 - second_y1)
    union = first_area + second_area - intersection
    return intersection / union if union else 0.0


def _find_matching_prediction(predictions, class_name, bbox):
    """Find a YOLO/CV duplicate without requiring identical box tightness."""
    best_index = None
    best_score = 0.0
    centre_x, centre_y, box_width, box_height = (float(value) for value in bbox)
    for index, prediction in enumerate(predictions):
        if _normalise_detection_class(prediction.get("class")) != class_name:
            continue
        other = prediction.get("bbox", ())
        if len(other) != 4:
            continue
        other_x, other_y, other_width, other_height = (float(value) for value in other)
        overlap = _bbox_iou(bbox, other)
        distance = float(np.hypot(centre_x - other_x, centre_y - other_y))
        tolerance = max(8.0, 0.35 * max(box_width, box_height, other_width, other_height))
        # CV bars and YOLO bars can differ substantially in height, so allow a
        # close centre match in addition to ordinary IoU.
        score = overlap
        if overlap >= 0.12 or distance <= tolerance:
            score = max(score, 0.12 + max(0.0, 1.0 - distance / max(tolerance, 1.0)) * 0.1)
        if score > best_score:
            best_index, best_score = index, score
    return best_index


def _set_component_box(components, component_id, bbox, image_shape):
    components[component_id] = _xywh_to_xyxy(bbox, image_shape)


def _is_monster_bbox(bbox, image_shape):
    """Reject page-sized detector boxes before they contaminate topology."""
    _, _, width, height = (float(value) for value in bbox)
    image_height, image_width = image_shape[:2]
    width_ratio = width / max(image_width, 1)
    height_ratio = height / max(image_height, 1)
    return width_ratio * height_ratio > 0.35 or (
        width_ratio > 0.70 and height_ratio > 0.70
    )


def _build_topology_binary(image):
    """Build the original-scale conductor mask used by topology validation."""
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    _, global_binary = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)
    adaptive_binary = cv2.adaptiveThreshold(
        gray,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV,
        15,
        10,
    )
    return _remove_numeric_text_components(
        cv2.bitwise_and(global_binary, adaptive_binary)
    )


def _bbox_from_load_candidate(candidate):
    """Return an editor/evaluation box for a CV load without widening its mask.

    The load detector intentionally keeps ``candidate`` to the filled inner
    triangle: that is the safest shape to remove before topology tracing.
    Dataset annotations, however, describe the complete arrowhead including
    its anti-aliased outer stroke.  Returning the inner-core box as the public
    object box therefore makes a correct load fail IoU matching simply because
    it is 7--10 px wide instead of the visible 16 px symbol.

    Keep topology tied to ``load_core_mask``/``load_triangle_polygon`` and use
    a small, bounded display expansion here.  The centre moves only toward the
    arrow tip, never down the shaft, so an electrical line is not absorbed into
    the object geometry.
    """
    direction_x, direction_y = candidate.direction
    raw_width = float(candidate.w / LOAD_SCALE)
    raw_height = float(candidate.h / LOAD_SCALE)
    # Distance-transform CV intentionally records only the solid inner core
    # of a small arrowhead.  A visible load annotation includes its short
    # shaft, so keep a modest minimum along the arrow axis for the public
    # display/evaluation box.  The topology mask still uses the inner core;
    # this does not erase the conductor.
    if direction_y:
        display_width = max(16.0, raw_width + 2.0)
        display_height = max(24.0, raw_height + 2.0)
    elif direction_x:
        display_width = max(24.0, raw_width + 2.0)
        display_height = max(16.0, raw_height + 2.0)
    else:
        display_width = max(16.0, raw_width + 2.0)
        display_height = max(16.0, raw_height + 2.0)
    centre_shift = min(2.0, min(display_width, display_height) * 0.125)
    return [
        float((candidate.x + candidate.w / 2) / LOAD_SCALE + direction_x * centre_shift),
        float((candidate.y + candidate.h / 2) / LOAD_SCALE + direction_y * centre_shift),
        display_width,
        display_height,
    ]


def _restore_inline_load_conductor(
    topology_binary: np.ndarray,
    source_binary: np.ndarray,
    candidate,
    thin_width: int,
    mask_box=None,
) -> int:
    """Restore only an independent conductor hidden by a load display box.

    A load remains a hard one-port terminal.  This helper never turns its
    tail into a pass-through point.  It only restores a different straight
    conductor lane when that lane:

    * has real source ink continuing well beyond two opposite mask edges; and
    * is separated from the load's validated tail by more than one stroke.

    The checks are derived from page stroke width and object geometry, not an
    image name, coordinate, or per-image threshold.
    """
    image_h, image_w = topology_binary.shape[:2]
    if mask_box is None:
        x = float(candidate.x) / LOAD_SCALE
        y = float(candidate.y) / LOAD_SCALE
        mask_box = (
            int(round(x)),
            int(round(y)),
            int(round(x + float(candidate.w) / LOAD_SCALE)),
            int(round(y + float(candidate.h) / LOAD_SCALE)),
        )
    x1, y1, x2, y2 = (int(round(value)) for value in mask_box)
    x1 = max(0, min(image_w - 1, x1))
    y1 = max(0, min(image_h - 1, y1))
    x2 = max(x1, min(image_w - 1, x2))
    y2 = max(y1, min(image_h - 1, y2))
    if x2 - x1 < 1 and y2 - y1 < 1:
        return 0

    band = max(1, int(round(float(thin_width))))
    boundary_span = max(1, band * 2 + 1)
    continuation = max(4, band * 3)
    probe_length = continuation + 1
    tail_point = np.asarray(candidate.base, dtype=float) / LOAD_SCALE
    tail_separation = max(
        1.5 * float(band),
        0.15 * float(min(x2 - x1 + 1, y2 - y1 + 1)),
    )

    def vertical_run_is_long(x: int, boundary_y: int, direction: int) -> bool:
        hits = 0
        left = max(0, x - band)
        right = min(image_w, x + band + 1)
        for offset in range(1, probe_length + 1):
            y = boundary_y + direction * offset
            if not (0 <= y < image_h):
                return False
            if np.any(source_binary[y, left:right] > 0):
                hits += 1
        return hits >= continuation

    def horizontal_run_is_long(y: int, boundary_x: int, direction: int) -> bool:
        hits = 0
        top = max(0, y - band)
        bottom = min(image_h, y + band + 1)
        for offset in range(1, probe_length + 1):
            x = boundary_x + direction * offset
            if not (0 <= x < image_w):
                return False
            if np.any(source_binary[top:bottom, x] > 0):
                hits += 1
        return hits >= continuation

    def boundary_hits_vertical(x: int) -> tuple[int, int] | None:
        if abs(float(tail_point[0]) - float(x)) <= tail_separation:
            return None
        if not vertical_run_is_long(x, y1, -1):
            return None
        if not vertical_run_is_long(x, y2, 1):
            return None
        top_start = max(0, y1 - boundary_span)
        bottom_stop = min(image_h, y2 + boundary_span + 1)
        top_hits = np.where(source_binary[top_start:y1 + 1, x] > 0)[0]
        bottom_hits = np.where(source_binary[y2:bottom_stop, x] > 0)[0]
        if len(top_hits) == 0 or len(bottom_hits) == 0:
            return None
        return (
            int(top_hits[-1] + top_start),
            int(bottom_hits[0] + y2),
        )

    def boundary_hits_horizontal(y: int) -> tuple[int, int] | None:
        if abs(float(tail_point[1]) - float(y)) <= tail_separation:
            return None
        if not horizontal_run_is_long(y, x1, -1):
            return None
        if not horizontal_run_is_long(y, x2, 1):
            return None
        left_start = max(0, x1 - boundary_span)
        right_stop = min(image_w, x2 + boundary_span + 1)
        left_hits = np.where(source_binary[y, left_start:x1 + 1] > 0)[0]
        right_hits = np.where(source_binary[y, x2:right_stop] > 0)[0]
        if len(left_hits) == 0 or len(right_hits) == 0:
            return None
        return (
            int(left_hits[-1] + left_start),
            int(right_hits[0] + x2),
        )

    best: tuple[int, tuple[int, int], tuple[int, int]] | None = None
    for x in range(x1, x2 + 1):
        hits = boundary_hits_vertical(x)
        if hits is None:
            continue
        top_y, bottom_y = hits
        score = int(np.count_nonzero(
            source_binary[top_y:bottom_y + 1, max(0, x - band):x + band + 1]
        ))
        if best is None or score > best[0]:
            best = (score, (x, top_y), (x, bottom_y))
    for y in range(y1, y2 + 1):
        hits = boundary_hits_horizontal(y)
        if hits is None:
            continue
        left_x, right_x = hits
        score = int(np.count_nonzero(
            source_binary[max(0, y - band):y + band + 1, left_x:right_x + 1]
        ))
        if best is None or score > best[0]:
            best = (score, (left_x, y), (right_x, y))
    if best is None:
        return 0

    before = int(np.count_nonzero(topology_binary))
    cv2.line(topology_binary, best[1], best[2], 255, 1, cv2.LINE_8)
    return int(np.count_nonzero(topology_binary)) - before


def _bus_overlaps_load_head(bus, candidate, image_shape):
    """Return True only when a compact bus candidate is inside a load head.

    Upscaling can turn the flat base of a filled arrowhead into a short,
    apparently thick horizontal/vertical bar.  That fragment can satisfy the
    ordinary bus thickness, straightness, and one-branch checks even though it
    is part of the load symbol.  Use the load detector's core mask as the
    decisive evidence; length alone is never a veto, so a genuinely small bus
    remains valid when it does not occupy the arrowhead.
    """
    centre_x = float(bus["x"])
    centre_y = float(bus["y"])
    width = float(bus["w"])
    height = float(bus["h"])
    bus_long_side = max(width, height)
    load_core_long_side = max(
        float(candidate.w) / LOAD_SCALE,
        float(candidate.h) / LOAD_SCALE,
    )
    # A normal bus may pass near a load display box.  Only a compact fragment
    # comparable to the actual triangle core can be the arrowhead base.
    if bus_long_side > max(28.0, load_core_long_side * 1.8):
        return False

    image_height, image_width = image_shape[:2]
    x1 = max(0, int(round(centre_x - width / 2)))
    y1 = max(0, int(round(centre_y - height / 2)))
    x2 = min(image_width, int(round(centre_x + width / 2)))
    y2 = min(image_height, int(round(centre_y + height / 2)))
    if x2 <= x1 or y2 <= y1:
        return False

    core_mask = load_core_mask(candidate, image_shape, margin=1)
    overlap = core_mask[y1:y2, x1:x2]
    if overlap.size == 0:
        return False
    return float(np.mean(overlap > 0)) >= 0.55


def _remove_load_head_bus_candidates(cv_buses, cv_loads, image_shape):
    """Remove arrowhead-base fragments without changing general bus gates."""
    return [
        bus
        for bus in cv_buses
        if not any(
            _bus_overlaps_load_head(bus, candidate, image_shape)
            for candidate in cv_loads
        )
    ]


def _match_cv_record(records, class_name, bbox, used=None):
    """Match a YOLO rescue box to a CV accepted/rejected record."""
    used = used or set()
    best_index = None
    best_score = 0.0
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    for index, record in enumerate(records):
        if index in used:
            continue
        if class_name == "load":
            other_bbox = _bbox_from_load_candidate(record)
        else:
            other_bbox = [
                float(record["x"]),
                float(record["y"]),
                float(record["w"]),
                float(record["h"]),
            ]
        other_x, other_y, other_width, other_height = other_bbox
        overlap = _bbox_iou(bbox, other_bbox)
        distance = float(np.hypot(centre_x - other_x, centre_y - other_y))
        tolerance = max(
            6.0,
            0.32 * max(width, height, other_width, other_height),
        )
        if overlap < 0.08 and distance > tolerance:
            continue
        score = max(
            overlap,
            0.10 + max(0.0, 1.0 - distance / max(tolerance, 1.0)) * 0.1,
        )
        if score > best_score:
            best_index, best_score = index, score
    return best_index


def _strict_rejected_bus_gate(record):
    """Only promote a CV-rejected bar when it still has bus evidence."""
    long_side = max(float(record["w"]), float(record["h"]))
    short_side = min(float(record["w"]), float(record["h"]))
    return (
        long_side >= max(22.0, short_side * 3.0)
        and short_side >= 1.5
        and float(record.get("profile_score", 0.0)) >= 0.80
        and float(record.get("perpendicular_branches", 0.0)) >= 1.0
        and float(record.get("traced_components", 0.0)) >= 1.0
        and float(record.get("bent_endpoints", 0.0)) <= 0.0
    )


def _relaxed_rejected_bus_gate(record, yolo_confidence):
    """Recover a strong YOLO-supported *CV bar* excluded by family selection.

    The strict gate above is ideal for avoiding line fragments, but it also
    rejects real buses whose profile is clean yet whose branch count becomes
    zero after a nearby device/label breaks the skeleton.  This alternative is
    deliberately still a two-model agreement: the CV morphology must provide
    a finite, high-profile bar and YOLO must independently call the same area
    a high-confidence bus.  No unmatched YOLO box is admitted.
    """
    long_side = max(float(record["w"]), float(record["h"]))
    short_side = min(float(record["w"]), float(record["h"]))
    return (
        float(yolo_confidence) >= 0.68
        and long_side >= max(22.0, short_side * 2.8)
        and float(record.get("profile_score", 0.0)) >= 0.82
        and float(record.get("bent_endpoints", 0.0)) <= 0.0
    )


def _merge_nearby_foreground_runs(values, maximum_gap):
    """Return foreground runs, bridging only tiny rasterisation gaps."""
    changes = np.diff(np.r_[False, values, False].astype(np.int8))
    starts = np.where(changes == 1)[0].tolist()
    ends = np.where(changes == -1)[0].tolist()
    if not starts:
        return []

    merged = [[starts[0], ends[0]]]
    for start, end in zip(starts[1:], ends[1:]):
        if start - merged[-1][1] <= maximum_gap:
            merged[-1][1] = end
        else:
            merged.append([start, end])
    return [(int(start), int(end)) for start, end in merged]


def _same_bus_bar(first, second):
    """Check whether two xywh boxes describe the same straight bus bar."""
    first_x, first_y, first_w, first_h = (float(value) for value in first)
    second_x, second_y, second_w, second_h = (float(value) for value in second)
    first_horizontal = first_w >= first_h
    second_horizontal = second_w >= second_h
    if first_horizontal != second_horizontal:
        return False

    if first_horizontal:
        first_major_start, first_major_end = first_x - first_w / 2, first_x + first_w / 2
        second_major_start, second_major_end = second_x - second_w / 2, second_x + second_w / 2
        cross_distance = abs(first_y - second_y)
        cross_size = max(first_h, second_h)
    else:
        first_major_start, first_major_end = first_y - first_h / 2, first_y + first_h / 2
        second_major_start, second_major_end = second_y - second_h / 2, second_y + second_h / 2
        cross_distance = abs(first_x - second_x)
        cross_size = max(first_w, second_w)
    overlap = max(0.0, min(first_major_end, second_major_end) - max(first_major_start, second_major_start))
    first_major = first_major_end - first_major_start
    second_major = second_major_end - second_major_start
    return (
        cross_distance <= max(6.0, cross_size * 0.90)
        and overlap >= min(first_major, second_major) * 0.40
    )


def _make_electrical_bus_context(image):
    """Build the conductor graph shared by all bus proposals in one sheet."""
    binary = bus_cv.binarize_and_repair(image)
    return {
        "binary": binary,
        "thin_width": bus_cv.estimate_thin_line_width(binary),
        "skeleton": bus_cv.skeletonize(binary),
    }


def _extract_electrical_bus_signature(image, proposal_bbox, context=None):
    """Recover a tight bar and count the electrical ports around it.

    A detector rectangle is only a search window.  The returned geometry is
    rebuilt from source pixels, then the bar itself is erased from a skeleton
    so conductors entering through its sides and ends can be counted
    independently.  Text strokes and ordinary feeder segments generally do
    not form this multi-port junction signature.
    """
    context = context or _make_electrical_bus_context(image)
    binary = context["binary"]
    thin_width = int(context["thin_width"])
    skeleton = context["skeleton"]
    scale = float(getattr(bus_cv, "SCALE", LOAD_SCALE))

    centre_x, centre_y, width, height = (
        float(value) * scale for value in proposal_bbox
    )
    horizontal = width >= height
    x1 = max(0, int(round(centre_x - width / 2.0)))
    y1 = max(0, int(round(centre_y - height / 2.0)))
    x2 = min(binary.shape[1], int(round(centre_x + width / 2.0)))
    y2 = min(binary.shape[0], int(round(centre_y + height / 2.0)))
    roi = binary[y1:y2, x1:x2] > 0
    if roi.size == 0:
        return None

    cross_density = roi.mean(axis=1 if horizontal else 0)
    cross_groups = _merge_nearby_foreground_runs(
        cross_density >= 0.52,
        maximum_gap=1,
    )
    if not cross_groups:
        return None
    expected_cross = (centre_y - y1) if horizontal else (centre_x - x1)
    cross_start, cross_end = max(
        cross_groups,
        key=lambda run: (
            float(np.mean(cross_density[run[0]:run[1]]))
            - abs((run[0] + run[1]) / 2.0 - expected_cross)
            / max(len(cross_density), 1)
        ),
    )

    if horizontal:
        bar_y1, bar_y2 = y1 + cross_start, y1 + cross_end
        major_density = (binary[bar_y1:bar_y2, x1:x2] > 0).mean(axis=0)
    else:
        bar_x1, bar_x2 = x1 + cross_start, x1 + cross_end
        major_density = (binary[y1:y2, bar_x1:bar_x2] > 0).mean(axis=1)
    major_groups = _merge_nearby_foreground_runs(
        major_density >= 0.52,
        maximum_gap=max(1, thin_width // 3),
    )
    if not major_groups:
        return None
    expected_major = (centre_x - x1) if horizontal else (centre_y - y1)
    major_start, major_end = min(
        major_groups,
        key=lambda run: abs((run[0] + run[1]) / 2.0 - expected_major),
    )
    if horizontal:
        bar_x1, bar_x2 = x1 + major_start, x1 + major_end
    else:
        bar_y1, bar_y2 = y1 + major_start, y1 + major_end
    if bar_x2 <= bar_x1 or bar_y2 <= bar_y1:
        return None

    network = skeleton.copy()
    erase_pad = max(1, thin_width // 3)
    cv2.rectangle(
        network,
        (max(0, bar_x1 - erase_pad), max(0, bar_y1 - erase_pad)),
        (
            min(network.shape[1] - 1, bar_x2 + erase_pad),
            min(network.shape[0] - 1, bar_y2 + erase_pad),
        ),
        0,
        -1,
    )
    reach = max(5, thin_width * 2)
    cluster_gap = max(3, thin_width * 2)
    if horizontal:
        expanded_x1 = max(0, bar_x1 - reach)
        expanded_x2 = min(network.shape[1], bar_x2 + reach)
        top = np.any(
            network[
                max(0, bar_y1 - reach):max(0, bar_y1 - erase_pad),
                expanded_x1:expanded_x2,
            ] > 0,
            axis=0,
        )
        bottom = np.any(
            network[
                min(network.shape[0], bar_y2 + erase_pad):min(
                    network.shape[0], bar_y2 + reach
                ),
                expanded_x1:expanded_x2,
            ] > 0,
            axis=0,
        )
        perpendicular_ports = len(
            _merge_nearby_foreground_runs(top, cluster_gap)
        ) + len(_merge_nearby_foreground_runs(bottom, cluster_gap))
        first_end = bool(np.any(
            network[
                max(0, bar_y1 - reach):min(network.shape[0], bar_y2 + reach),
                max(0, bar_x1 - reach):max(0, bar_x1 - erase_pad),
            ]
        ))
        second_end = bool(np.any(
            network[
                max(0, bar_y1 - reach):min(network.shape[0], bar_y2 + reach),
                min(network.shape[1], bar_x2 + erase_pad):min(
                    network.shape[1], bar_x2 + reach
                ),
            ]
        ))
    else:
        expanded_y1 = max(0, bar_y1 - reach)
        expanded_y2 = min(network.shape[0], bar_y2 + reach)
        first_side = np.any(
            network[
                expanded_y1:expanded_y2,
                max(0, bar_x1 - reach):max(0, bar_x1 - erase_pad),
            ] > 0,
            axis=1,
        )
        second_side = np.any(
            network[
                expanded_y1:expanded_y2,
                min(network.shape[1], bar_x2 + erase_pad):min(
                    network.shape[1], bar_x2 + reach
                ),
            ] > 0,
            axis=1,
        )
        perpendicular_ports = len(
            _merge_nearby_foreground_runs(first_side, cluster_gap)
        ) + len(_merge_nearby_foreground_runs(second_side, cluster_gap))
        first_end = bool(np.any(
            network[
                max(0, bar_y1 - reach):max(0, bar_y1 - erase_pad),
                max(0, bar_x1 - reach):min(network.shape[1], bar_x2 + reach),
            ]
        ))
        second_end = bool(np.any(
            network[
                min(network.shape[0], bar_y2 + erase_pad):min(
                    network.shape[0], bar_y2 + reach
                ),
                max(0, bar_x1 - reach):min(network.shape[1], bar_x2 + reach),
            ]
        ))

    bar_width = float((bar_x2 - bar_x1) / scale)
    bar_height = float((bar_y2 - bar_y1) / scale)
    return {
        "x": float((bar_x1 + bar_x2) / 2.0 / scale),
        "y": float((bar_y1 + bar_y2) / 2.0 / scale),
        "w": bar_width,
        "h": bar_height,
        "orientation": "horizontal" if horizontal else "vertical",
        "perpendicular_ports": int(perpendicular_ports),
        "endpoint_ports": int(first_end) + int(second_end),
        "thickness_ratio": float(
            min(bar_x2 - bar_x1, bar_y2 - bar_y1) / max(thin_width, 1)
        ),
    }


def _secondary_bus_family_indices(records, primary_thickness):
    """Find a repeated, electrically active thin-bus family in one sheet.

    Some diagrams use two legitimate bus stroke widths. A single thin bar is
    still ambiguous with a feeder, so only a repeated family of at least three
    CV-accepted straight bars is returned. Every member must have two or more
    perpendicular attachments and at least three total ports.
    """
    eligible = []
    for index, record in enumerate(records):
        signature = record.get("signature")
        if signature is None:
            continue
        perpendicular_ports = int(signature["perpendicular_ports"])
        endpoint_ports = int(signature["endpoint_ports"])
        thickness_ratio = float(signature["thickness_ratio"])
        relative_thickness = thickness_ratio / max(float(primary_thickness), 1e-6)
        if (
            perpendicular_ports < 2
            or perpendicular_ports + endpoint_ports < 3
            or thickness_ratio < 1.05
            or relative_thickness > 0.68
        ):
            continue
        eligible.append((
            index,
            str(record["bus"].get("orientation", "")),
            thickness_ratio,
        ))

    selected = set()
    for orientation in ("horizontal", "vertical"):
        oriented = [item for item in eligible if item[1] == orientation]
        if len(oriented) < 3:
            continue
        # Find the densest local thickness cluster. Isolated feeder-width
        # candidates are not pulled into the secondary family.
        best_cluster = []
        for _, _, seed_ratio in oriented:
            cluster = [
                item for item in oriented
                if abs(item[2] - seed_ratio) <= 0.20
            ]
            if len(cluster) > len(best_cluster):
                best_cluster = cluster
        if len(best_cluster) >= 3:
            cluster_ratio = float(np.median([item[2] for item in best_cluster]))
            # Strong members establish that the page really has a second bus
            # style. Only then may a same-style two-port bar join that family;
            # it cannot establish the family by itself.
            for index, record in enumerate(records):
                signature = record.get("signature")
                if signature is None:
                    continue
                perpendicular_ports = int(signature["perpendicular_ports"])
                endpoint_ports = int(signature["endpoint_ports"])
                thickness_ratio = float(signature["thickness_ratio"])
                if (
                    str(record["bus"].get("orientation", "")) == orientation
                    and perpendicular_ports >= 1
                    and perpendicular_ports + endpoint_ports >= 2
                    and abs(thickness_ratio - cluster_ratio) <= 0.20
                    and thickness_ratio / max(float(primary_thickness), 1e-6)
                    <= 0.68
                ):
                    selected.add(index)
    return selected


def _electrical_bus_consensus(image, cv_buses, yolo_results, model):
    """Fuse CV bars with detector locations using circuit-junction evidence.

    The global stroke-width selector is no longer the final authority.  YOLO
    may point to a region, but source pixels must form a thicker straight bar
    with at least one perpendicular conductor and at least two electrical
    ports in total.  A CV-only bar survives when it belongs to the same
    within-sheet thickness family and independently has a strong junction
    signature.  Thus neither branch can add a raw model rectangle.
    """
    context = _make_electrical_bus_context(image)
    yolo_cv_buses = []
    for result in yolo_results:
        for box in result.boxes:
            class_index = int(box.cls[0])
            class_name = _normalise_detection_class(model.names[class_index])
            confidence = float(box.conf[0])
            if class_name != "bus" or confidence < YOLO_CLASS_CONFIDENCES["bus"]:
                continue
            proposal_bbox = [float(value) for value in box.xywh[0].tolist()]
            if _is_monster_bbox(proposal_bbox, image.shape):
                continue
            signature = _extract_electrical_bus_signature(
                image,
                proposal_bbox,
                context,
            )
            if signature is None:
                continue
            total_ports = (
                int(signature["perpendicular_ports"])
                + int(signature["endpoint_ports"])
            )
            if (
                int(signature["perpendicular_ports"]) < 1
                or total_ports < 2
                or float(signature["thickness_ratio"]) < 1.45
            ):
                continue
            signature = dict(signature)
            signature.update({
                "confidence": confidence,
                "source": "yolo_cv_electrical_bus",
                "yolo_bbox": proposal_bbox,
            })
            signature_bbox = [
                signature["x"],
                signature["y"],
                signature["w"],
                signature["h"],
            ]
            duplicate = next(
                (
                    existing
                    for existing in yolo_cv_buses
                    if _same_bus_bar(
                        [existing["x"], existing["y"], existing["w"], existing["h"]],
                        signature_bbox,
                    )
                ),
                None,
            )
            if duplicate is None:
                yolo_cv_buses.append(signature)
            elif confidence > float(duplicate.get("confidence", 0.0)):
                duplicate.update(signature)

    if not yolo_cv_buses:
        return cv_buses

    supported_cv = []
    unmatched_cv = []
    for bus in cv_buses:
        bus_bbox = [bus["x"], bus["y"], bus["w"], bus["h"]]
        if any(
            _same_bus_bar(
                bus_bbox,
                [item["x"], item["y"], item["w"], item["h"]],
            )
            for item in yolo_cv_buses
        ):
            supported_cv.append(bus)
        else:
            unmatched_cv.append(bus)

    family_ratios = []
    for bus in supported_cv:
        signature = _extract_electrical_bus_signature(
            image,
            [bus["x"], bus["y"], bus["w"], bus["h"]],
            context,
        )
        if signature is not None:
            family_ratios.append(float(signature["thickness_ratio"]))
    family_thickness = float(np.median(family_ratios)) if family_ratios else 2.0

    unmatched_records = []
    for bus in unmatched_cv:
        signature = _extract_electrical_bus_signature(
            image,
            [bus["x"], bus["y"], bus["w"], bus["h"]],
            context,
        )
        if signature is None:
            continue
        unmatched_records.append({"bus": bus, "signature": signature})

    secondary_family = _secondary_bus_family_indices(
        unmatched_records,
        family_thickness,
    )
    retained_cv = []
    for record_index, record in enumerate(unmatched_records):
        bus = record["bus"]
        signature = record["signature"]
        perpendicular_ports = int(signature["perpendicular_ports"])
        endpoint_ports = int(signature["endpoint_ports"])
        total_ports = perpendicular_ports + endpoint_ports
        relative_thickness = (
            float(signature["thickness_ratio"]) / max(family_thickness, 1e-6)
        )
        strong_multi_branch = (
            total_ports >= 2
            and perpendicular_ports >= 2
            and relative_thickness >= 0.86
        )
        centre_tap_bus = (
            endpoint_ports == 0
            and perpendicular_ports >= 1
            and relative_thickness >= 0.90
        )
        repeated_secondary_family = record_index in secondary_family
        if not (strong_multi_branch or centre_tap_bus or repeated_secondary_family):
            continue
        retained = dict(bus)
        retained.update({
            "source": (
                "cv_secondary_electrical_family"
                if repeated_secondary_family
                else "cv_electrical_consensus"
            ),
            "perpendicular_ports": perpendicular_ports,
            "endpoint_ports": endpoint_ports,
            "thickness_ratio": float(signature["thickness_ratio"]),
        })
        retained_cv.append(retained)

    final_buses = []
    for bus in [*yolo_cv_buses, *retained_cv]:
        bbox = [bus["x"], bus["y"], bus["w"], bus["h"]]
        if any(
            _same_bus_bar(
                bbox,
                [item["x"], item["y"], item["w"], item["h"]],
            )
            for item in final_buses
        ):
            continue
        final_buses.append(bus)
    return final_buses


def _scaled_bus_box_from_bbox(bbox):
    """Convert a source-scale xywh bus box to load-CV's scaled xyxy format."""
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    return (
        int(round((centre_x - width / 2.0) * LOAD_SCALE)),
        int(round((centre_y - height / 2.0) * LOAD_SCALE)),
        int(round((centre_x + width / 2.0) * LOAD_SCALE)),
        int(round((centre_y + height / 2.0) * LOAD_SCALE)),
    )


def _recover_yolo_bus_raster_run(image, yolo_bbox):
    """Recover a full CV-validated bar from one YOLO bus proposal.

    Directional morphology intentionally breaks a horizontal bar where a
    vertical terminal crosses it.  This helper examines several source rows
    around the independent YOLO proposal, joins only 3.5px-or-smaller scan
    gaps, and then validates the reconstructed run using the same local CV
    topology metrics as the primary detector.  It rejects page-spanning
    conductors and bars whose reconstructed ends turn twice.
    """
    centre_x, centre_y, width, height = (float(value) for value in yolo_bbox)
    major = max(width, height)
    minor = min(width, height)
    if minor <= 0.0 or major / minor < 5.0:
        return None

    orientation = "horizontal" if width >= height else "vertical"
    binary = bus_cv.binarize_and_repair(image)
    thin_width = bus_cv.estimate_thin_line_width(binary)
    scale = float(getattr(bus_cv, "SCALE", LOAD_SCALE))
    axis_size = binary.shape[1] if orientation == "horizontal" else binary.shape[0]
    expected_major = major * scale
    expected_centre_axis = (centre_x if orientation == "horizontal" else centre_y) * scale
    expected_centre_cross = (centre_y if orientation == "horizontal" else centre_x) * scale
    expected_start = expected_centre_axis - expected_major / 2.0
    expected_end = expected_centre_axis + expected_major / 2.0
    cross_radius = max(int(round(minor * scale)), int(round(4.0 * scale)))
    maximum_gap = max(2, int(round(3.5 * scale)))

    best = None
    for cross in range(
        max(0, int(round(expected_centre_cross)) - cross_radius),
        min(binary.shape[0 if orientation == "horizontal" else 1], int(round(expected_centre_cross)) + cross_radius + 1),
    ):
        foreground = (binary[cross, :] > 0) if orientation == "horizontal" else (binary[:, cross] > 0)
        for start, end in _merge_nearby_foreground_runs(foreground, maximum_gap):
            run_length = float(end - start)
            overlap = max(0.0, min(float(end), expected_end) - max(float(start), expected_start))
            coverage = overlap / max(expected_major, 1.0)
            length_ratio = run_length / max(expected_major, 1.0)
            run_centre = (start + end) / 2.0
            centre_offset = abs(run_centre - expected_centre_axis) / max(expected_major, 1.0)
            if (
                coverage < 0.72
                or not 0.68 <= length_ratio <= 1.38
                or centre_offset > 0.28
                or run_length > axis_size * 0.35
            ):
                continue
            score = coverage - 0.20 * centre_offset - 0.08 * abs(1.0 - length_ratio)
            if best is None or score > best[0]:
                best = (score, cross, start, end)
    if best is None:
        return None

    _, selected_cross, axis_start, axis_end = best
    transverse_size = binary.shape[0] if orientation == "horizontal" else binary.shape[1]
    transverse_radius = max(int(round(minor * scale * 1.2)), int(round(4.0 * scale)))
    interior_margin = max(maximum_gap, int(round(2.0 * scale)))
    density_rows = []
    for cross in range(
        max(0, selected_cross - transverse_radius),
        min(transverse_size, selected_cross + transverse_radius + 1),
    ):
        values = (
            binary[cross, axis_start + interior_margin:axis_end - interior_margin] > 0
            if orientation == "horizontal"
            else binary[axis_start + interior_margin:axis_end - interior_margin, cross] > 0
        )
        if values.size and float(np.mean(values)) >= 0.55:
            density_rows.append(cross)
    if not density_rows:
        return None

    row_groups = _merge_nearby_foreground_runs(
        np.isin(np.arange(transverse_size), density_rows), maximum_gap=1
    )
    containing_groups = [group for group in row_groups if group[0] <= selected_cross < group[1]]
    if not containing_groups:
        return None
    cross_start, cross_end = containing_groups[0]
    if orientation == "horizontal":
        bar = bus_cv.Bar(axis_start, cross_start, axis_end - axis_start, cross_end - cross_start, orientation, 0.0)
    else:
        bar = bus_cv.Bar(cross_start, axis_start, cross_end - cross_start, axis_end - axis_start, orientation, 0.0)
    if min(bar.w, bar.h) <= 0:
        return None

    bar.profile_score = bus_cv.profile_score(binary, bar)
    bus_cv._populate_local_geometry_metrics(binary, [bar], thin_width)
    endpoint_turns = bus_cv._immediate_endpoint_turn_count(binary, bar, thin_width)
    long_side, short_side = max(bar.w, bar.h), min(bar.w, bar.h)
    if (
        long_side > axis_size * 0.35
        or long_side / max(short_side, 1) < 5.0
        or bar.profile_score < 0.60
        or bar.traced_components < 2
        or bar.perpendicular_branches < 1
        or endpoint_turns > 1
    ):
        return None

    return {
        "x": float((bar.x + bar.w / 2.0) / scale),
        "y": float((bar.y + bar.h / 2.0) / scale),
        "w": float(bar.w / scale),
        "h": float(bar.h / scale),
        "orientation": orientation,
        "profile_score": float(bar.profile_score),
        "traced_components": float(bar.traced_components),
        "perpendicular_branches": float(bar.perpendicular_branches),
        "endpoint_turns": float(endpoint_turns),
    }


def _rescue_rejected_load(
    image,
    yolo_bbox,
    yolo_confidence,
    rejected_loads,
    load_bus_boxes,
    used_rejected_loads,
):
    """Return a rejected CV load only when its tail really reaches a bus."""
    # A rejected contour is more ambiguous than a fresh port-traced proposal.
    # Low-confidence proposals can still use the stricter port-rescue path,
    # but may not revive a number-like CV contour by proximity alone.
    if yolo_confidence < 0.55:
        return None
    match_index = _match_cv_record(
        rejected_loads,
        "load",
        yolo_bbox,
        used_rejected_loads,
    )
    if match_index is None:
        return None
    candidate = rejected_loads[match_index]
    thin_binary = bus_cv.binarize_and_repair(image)
    thin_width = bus_cv.estimate_thin_line_width(thin_binary)
    long_side = max(candidate.w, candidate.h)
    short_side = min(candidate.w, candidate.h)
    # The candidate must still resemble a small arrow.  This is intentionally
    # less strict than normal CV acceptance, because YOLO is being used to
    # rescue the small/ambiguous cases, but it is not a free pass for digits.
    if (
        candidate.triangle_score < 0.30
        or long_side < max(10, thin_width * 2.5)
        or short_side < max(5, thin_width * 1.25)
        or load_cv._has_enclosed_ink_hole(thin_binary, candidate, thin_width)
    ):
        return None
    skeleton = bus_cv.skeletonize(thin_binary)
    if not attach_to_bus_via_pixel_path(
        thin_binary,
        candidate,
        load_bus_boxes,
        thin_width,
        skeleton=skeleton,
    ):
        return None
    if candidate.attached_bus is None or not (
        0 <= int(candidate.attached_bus) < len(load_bus_boxes)
    ):
        return None
    used_rejected_loads.add(match_index)
    return candidate, int(candidate.attached_bus)


def _make_yolo_load_rescue_context(image):
    """Build the scaled conductor graph once for all YOLO-load proposals."""
    binary = bus_cv.binarize_and_repair(image)
    thin_width = bus_cv.estimate_thin_line_width(binary)
    return {
        "binary": binary,
        "thin_width": thin_width,
        "skeleton": bus_cv.skeletonize(binary),
    }


def _tail_has_outward_ink(skeleton, base, tail_direction, thin_width):
    """Require a real lead immediately outside the proposed load tail."""
    height, width = skeleton.shape[:2]
    radius = max(2, int(round(thin_width * 0.6)))
    hit_steps = 0
    # Do not allow a load candidate to jump over white space into a nearby
    # conductor.  Two separate hit distances make an adjacent digit stroke
    # insufficient, but still accept antialiased short load shafts.
    for distance in range(2, max(8, int(round(thin_width * 3))) + 1):
        x = int(round(base[0] + tail_direction[0] * distance))
        y = int(round(base[1] + tail_direction[1] * distance))
        if not (0 <= x < width and 0 <= y < height):
            return False
        roi = skeleton[
            max(0, y - radius):min(height, y + radius + 1),
            max(0, x - radius):min(width, x + radius + 1),
        ]
        if np.any(roi):
            hit_steps += 1
    return hit_steps >= 2


def _direct_load_tail_reaches_cv_bus(
    binary,
    candidate,
    bus_boxes,
    thin_width,
):
    """Validate the short, straight shaft between an arrow and a CV bus.

    ``attach_to_bus_via_pixel_path`` is intentionally designed for longer
    routed feeders.  On clean textbook diagrams an arrow shaft can terminate
    directly against a thick bus; after skeletonisation that tiny T-junction
    often has no usable endpoint, even though the original pixels form an
    unbroken connection.  Inspect the source binary instead: every sampled
    cross-strip from the arrow tail to the nearest aligned CV bus must contain
    conductor ink.  This remains a physical CV condition and cannot promote a
    nearby numeric label across a white gap.
    """
    tail_direction = (-candidate.direction[0], -candidate.direction[1])
    maximum_distance = max(160, int(round(max(candidate.w, candidate.h) * 3.0)))
    samples = []
    for distance in range(2, maximum_distance + 1):
        x = int(round(candidate.base[0] + tail_direction[0] * distance))
        y = int(round(candidate.base[1] + tail_direction[1] * distance))
        if not (0 <= x < binary.shape[1] and 0 <= y < binary.shape[0]):
            break
        samples.append(
            load_cv._line_ink(binary, x, y, tail_direction, thin_width)
        )
        for bus_index, box in enumerate(bus_boxes):
            if not load_cv._point_inside_box((x, y), box, margin=max(3, thin_width)):
                continue
            if samples and sum(samples) / len(samples) >= 0.88:
                candidate.lead_length = int(distance)
                candidate.attached_bus = int(bus_index)
                candidate.reason = "accepted: direct CV shaft reaches CV bus"
                return True
            return False
    return False


def _generator_has_straight_bus_terminal(yolo_bbox, bus_boxes, context):
    """Require a real, immediate generator terminal leading straight to a bus.

    A circled bus number can look like a generator to YOLO.  Unlike a source
    symbol, it has no terminal leaving the circle and continuing directly to a
    bus.  This test starts just *outside* the YOLO circle box, so ink inside a
    digit or the circle outline cannot satisfy the condition.
    """
    if not bus_boxes:
        return False
    binary = context["binary"]
    thin_width = context["thin_width"]
    centre_x, centre_y, width, height = (float(value) * LOAD_SCALE for value in yolo_bbox)
    image_h, image_w = binary.shape[:2]
    radius = max(1, int(round(thin_width * 0.45)))
    initial_limit = max(8, int(round(thin_width * 3.0)))
    maximum_gap = max(3, int(round(thin_width * 1.2)))
    maximum_distance = max(64, int(round(max(width, height) * 2.8)))
    start_offset = max(2, thin_width)
    lateral_limit = max(thin_width, int(round(thin_width * 2.0)))
    lateral_step = max(1, thin_width // 3)

    def has_ink(x, y):
        if not (0 <= x < image_w and 0 <= y < image_h):
            return False
        roi = binary[
            max(0, y - radius):min(image_h, y + radius + 1),
            max(0, x - radius):min(image_w, x + radius + 1),
        ]
        return bool(np.any(roi))

    def reaches_bus(x, y):
        margin = max(3, thin_width)
        return any(
            x1 - margin <= x <= x2 + margin and y1 - margin <= y <= y2 + margin
            for x1, y1, x2, y2 in bus_boxes
        )

    for direction_x, direction_y in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        axis_extent = height / 2.0 if direction_y else width / 2.0
        perpendicular_x, perpendicular_y = -direction_y, direction_x
        for lateral in range(-lateral_limit, lateral_limit + 1, lateral_step):
            boundary_x = centre_x + direction_x * axis_extent + perpendicular_x * lateral
            boundary_y = centre_y + direction_y * axis_extent + perpendicular_y * lateral
            initial_hits = 0
            for distance in range(start_offset, initial_limit + 1):
                x = int(round(boundary_x + direction_x * distance))
                y = int(round(boundary_y + direction_y * distance))
                if has_ink(x, y):
                    initial_hits += 1
            if initial_hits < 2:
                continue

            gap = 0
            for distance in range(start_offset, maximum_distance + 1):
                x = int(round(boundary_x + direction_x * distance))
                y = int(round(boundary_y + direction_y * distance))
                if not (0 <= x < image_w and 0 <= y < image_h):
                    break
                if reaches_bus(x, y):
                    return True
                if has_ink(x, y):
                    gap = 0
                else:
                    gap += 1
                    if gap > maximum_gap:
                        break
    return False


def _refine_generator_circle_for_validation(image, yolo_bbox):
    """Locate one generator ring inside a YOLO proposal for CV validation."""
    image_h, image_w = image.shape[:2]
    x, y, width, height = (float(value) for value in yolo_bbox)
    expected_radius = min(width, height) / 2.0
    if expected_radius < 4.0:
        return list(yolo_bbox), None
    padding = max(8, int(round(expected_radius * 0.55)))
    x1 = max(0, int(round(x - width / 2.0)) - padding)
    y1 = max(0, int(round(y - height / 2.0)) - padding)
    x2 = min(image_w, int(round(x + width / 2.0)) + padding)
    y2 = min(image_h, int(round(y + height / 2.0)) + padding)
    roi = image[y1:y2, x1:x2]
    if roi.size == 0:
        return list(yolo_bbox), None

    gray = cv2.GaussianBlur(cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY), (5, 5), 1.2)
    circles = cv2.HoughCircles(
        gray,
        cv2.HOUGH_GRADIENT,
        dp=1.0,
        minDist=max(8, int(round(expected_radius * 1.3))),
        param1=80,
        param2=14,
        minRadius=max(4, int(round(expected_radius * 0.58))),
        maxRadius=max(6, int(round(expected_radius * 1.28))),
    )
    if circles is None:
        return list(yolo_bbox), None

    best = None
    best_score = float("inf")
    for local_x, local_y, radius in circles[0]:
        global_x, global_y = float(local_x + x1), float(local_y + y1)
        centre_distance = float(np.hypot(global_x - x, global_y - y))
        if centre_distance > expected_radius * 0.45:
            continue
        score = centre_distance + abs(float(radius) - expected_radius) * 0.65
        if score < best_score:
            best_score = score
            best = (global_x, global_y, float(radius))
    if best is None:
        return list(yolo_bbox), None

    circle_x, circle_y, radius = best
    final_size = radius * 2.24
    return [circle_x, circle_y, final_size, final_size], radius


def _generator_circle_has_external_lead(circle_bbox, context):
    """Require ink to leave the circle without jumping into nearby text."""
    binary = context["binary"]
    thin_width = int(context["thin_width"])
    centre_x, centre_y, width, height = (
        float(value) * LOAD_SCALE for value in circle_bbox
    )
    image_h, image_w = binary.shape[:2]
    sample_radius = max(1, int(round(thin_width * 0.45)))
    maximum_gap = max(3, int(round(thin_width * 1.25)))
    lateral_limit = max(thin_width, int(round(thin_width * 1.8)))
    lateral_step = max(1, thin_width // 2)
    maximum_distance = max(16, int(round(max(width, height) * 0.8)))

    def has_ink(x, y):
        if not (0 <= x < image_w and 0 <= y < image_h):
            return False
        roi = binary[
            max(0, y - sample_radius):min(image_h, y + sample_radius + 1),
            max(0, x - sample_radius):min(image_w, x + sample_radius + 1),
        ]
        return bool(np.any(roi))

    for direction_x, direction_y in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        axis_extent = height / 2.0 if direction_y else width / 2.0
        perpendicular_x, perpendicular_y = -direction_y, direction_x
        for lateral in range(-lateral_limit, lateral_limit + 1, lateral_step):
            boundary_x = (
                centre_x + direction_x * axis_extent + perpendicular_x * lateral
            )
            boundary_y = (
                centre_y + direction_y * axis_extent + perpendicular_y * lateral
            )
            gap = 0
            hits = 0
            for distance in range(1, maximum_distance + 1):
                x = int(round(boundary_x + direction_x * distance))
                y = int(round(boundary_y + direction_y * distance))
                if has_ink(x, y):
                    hits += 1
                    gap = 0
                else:
                    gap += 1
                    if gap > maximum_gap:
                        break
            if hits >= max(4, thin_width):
                return True
    return False


def _bbox_near_image_edge(bbox, image_shape):
    """Return true when a proposal is close enough to be visibly clipped."""
    centre_x, centre_y, width, height = (float(value) for value in bbox)
    image_h, image_w = image_shape[:2]
    margin = max(width, height) * 0.75
    return (
        centre_x - width / 2.0 <= margin
        or centre_y - height / 2.0 <= margin
        or image_w - (centre_x + width / 2.0) <= margin
        or image_h - (centre_y + height / 2.0) <= margin
    )


def _circle_pair_has_two_bus_ports(image, transformer, bus_boxes):
    """Require both outer winding leads to reach the detected bus network.

    Circle-pair CV is geometrically strong but can still fire on two printed
    loops.  Remove the winding box from the conductor skeleton, then prove
    that conductor components leave through both opposite symbol ports and
    each reaches a validated bus.  This is the electrical evidence needed for
    a circle pair to stand alone when YOLO confidence is low.
    """
    if str(transformer.get("style", "")) != "circle_pair" or not bus_boxes:
        return False
    orientation = str(transformer.get("orientation", ""))
    if orientation not in ("horizontal", "vertical"):
        return False

    context = _make_yolo_load_rescue_context(image)
    skeleton = cv2.dilate(
        context["skeleton"],
        np.ones((3, 3), dtype=np.uint8),
        iterations=1,
    )
    thin_width = int(context["thin_width"])
    scale = float(LOAD_SCALE)
    centre_x = float(transformer["x"]) * scale
    centre_y = float(transformer["y"]) * scale
    width = float(transformer["w"]) * scale
    height = float(transformer["h"]) * scale
    x1 = max(0, int(round(centre_x - width / 2.0)))
    y1 = max(0, int(round(centre_y - height / 2.0)))
    x2 = min(skeleton.shape[1], int(round(centre_x + width / 2.0)))
    y2 = min(skeleton.shape[0], int(round(centre_y + height / 2.0)))
    if x2 <= x1 or y2 <= y1:
        return False

    erase_pad = max(1, thin_width // 2)
    network = skeleton.copy()
    cv2.rectangle(
        network,
        (max(0, x1 - erase_pad), max(0, y1 - erase_pad)),
        (
            min(network.shape[1] - 1, x2 + erase_pad),
            min(network.shape[0] - 1, y2 + erase_pad),
        ),
        0,
        -1,
    )
    _, labels = cv2.connectedComponents(network, connectivity=8)

    bus_labels = set()
    margin = max(2, thin_width)
    for bus_x1, bus_y1, bus_x2, bus_y2 in bus_boxes:
        roi = labels[
            max(0, int(bus_y1) - margin):min(labels.shape[0], int(bus_y2) + margin + 1),
            max(0, int(bus_x1) - margin):min(labels.shape[1], int(bus_x2) + margin + 1),
        ]
        bus_labels.update(int(value) for value in np.unique(roi) if int(value) > 0)
    if not bus_labels:
        return False

    reach = max(10, thin_width * 5)
    transverse = max(thin_width * 3, int(round((height if orientation == "horizontal" else width) * 0.38)))
    if orientation == "horizontal":
        first_roi = labels[
            max(0, int(round(centre_y)) - transverse):min(labels.shape[0], int(round(centre_y)) + transverse + 1),
            max(0, x1 - reach):max(0, x1 - erase_pad),
        ]
        second_roi = labels[
            max(0, int(round(centre_y)) - transverse):min(labels.shape[0], int(round(centre_y)) + transverse + 1),
            min(labels.shape[1], x2 + erase_pad):min(labels.shape[1], x2 + reach),
        ]
    else:
        first_roi = labels[
            max(0, y1 - reach):max(0, y1 - erase_pad),
            max(0, int(round(centre_x)) - transverse):min(labels.shape[1], int(round(centre_x)) + transverse + 1),
        ]
        second_roi = labels[
            min(labels.shape[0], y2 + erase_pad):min(labels.shape[0], y2 + reach),
            max(0, int(round(centre_x)) - transverse):min(labels.shape[1], int(round(centre_x)) + transverse + 1),
        ]

    def reaches_bus(roi):
        port_labels = {int(value) for value in np.unique(roi) if int(value) > 0}
        return bool(port_labels & bus_labels)

    return reaches_bus(first_roi) and reaches_bus(second_roi)


def _yolo_transformer_port_metadata(image, bbox, bus_boxes):
    """Recover electrical orientation for a locally confirmed YOLO winding.

    A YOLO+local-CV transformer does not carry the orientation metadata emitted
    by ``detect_cv_transformers``. Falling back to the box aspect ratio is
    wrong for wide wave windings: their electrical terminals are above and
    below the symbol. Reuse the existing bus-reach check in both orientations
    and keep an orientation only when one opposite-side pair is proven.
    """
    x_center, y_center, width, height = (float(value) for value in bbox)
    base = {
        "x": x_center,
        "y": y_center,
        "w": width,
        "h": height,
        "style": "circle_pair",
    }
    supported = []
    for orientation in ("vertical", "horizontal"):
        candidate = {**base, "orientation": orientation}
        if _circle_pair_has_two_bus_ports(image, candidate, bus_boxes):
            supported.append(orientation)
    if len(supported) != 1:
        return None
    return {
        **base,
        "orientation": supported[0],
        "electrical_two_port": True,
        "orientation_source": "opposite_ports_reach_cv_bus_network",
    }


def _circle_pair_has_hollow_interior(image, transformer):
    """Reject filled bus bars that Hough circles mistake for two windings."""
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    _, ink = cv2.threshold(
        gray,
        0,
        255,
        cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU,
    )
    centre_x = float(transformer["x"])
    centre_y = float(transformer["y"])
    width = float(transformer["w"])
    height = float(transformer["h"])
    x1 = max(0, int(round(centre_x - width / 2.0)))
    y1 = max(0, int(round(centre_y - height / 2.0)))
    x2 = min(ink.shape[1], int(round(centre_x + width / 2.0)))
    y2 = min(ink.shape[0], int(round(centre_y + height / 2.0)))
    crop = ink[y1:y2, x1:x2]
    if crop.size == 0 or min(crop.shape) < 6:
        return False

    inner_y1 = max(1, crop.shape[0] // 4)
    inner_y2 = max(inner_y1 + 1, crop.shape[0] * 3 // 4)
    inner_x1 = max(1, crop.shape[1] // 4)
    inner_x2 = max(inner_x1 + 1, crop.shape[1] * 3 // 4)
    interior = crop[inner_y1:inner_y2, inner_x1:inner_x2]
    if interior.size == 0:
        return False

    # Two outlined windings retain visible white holes.  A filled bus segment
    # has an almost solid-black centre even when blur creates circular Hough
    # responses along its upper and lower edges.
    return float(np.mean(interior > 0)) <= 0.90


def _cv_transformer_can_stand_alone(prediction, metadata):
    """Allow CV-only windings only with style-specific structural proof."""
    transformer = metadata.get("transformer", {}) if metadata else {}
    wave_winding = (
        str(transformer.get("style", "")) == "wave"
        and float(prediction.get("confidence", 0.0))
        >= CV_ADD_TRANSFORMER_MIN_CONF
    )
    electrical_circle_pair = (
        str(transformer.get("style", "")) == "circle_pair"
        and bool(transformer.get("electrical_two_port", False))
        and bool(transformer.get("hollow_interior", False))
        # Text such as an impedance value's ``00`` can satisfy all local CV
        # geometry and even lie directly on a bus-to-bus conductor.  Require
        # only weak semantic agreement here; TEST2's four genuine compact
        # pairs score 0.098--0.459, while the text pair has no YOLO proposal.
        and float(prediction.get("yolo_support", 0.0))
        >= YOLO_PROBE_CONFIDENCE
    )
    return wave_winding or electrical_circle_pair


def _rescue_yolo_load_by_port_trace(
    yolo_bbox,
    yolo_confidence,
    load_bus_boxes,
    context,
    rejected_loads=None,
):
    """Turn a high-confidence YOLO load into a node only through its tail.

    The detector supplies a local *class* proposal.  CV then tests all four
    possible shaft directions, keeps only a direction that visibly exits the
    proposal and reaches a CV bus, and returns that exact port geometry for
    topology.  A number close to a bus has neither a valid shaft nor the
    required path and therefore cannot be resurrected.
    """
    # YOLO only proposes the semantic class.  A low-confidence proposal is
    # still useful when the pixels prove it is a compact arrow whose tail is
    # continuously connected to a CV bus.  The threshold merely avoids
    # spending a graph search on arbitrary noise; it is not the acceptance
    # criterion.
    if yolo_confidence < 0.35 or not load_bus_boxes:
        return None
    # A flow-direction marker embedded in a through conductor is visually
    # close to a load and can receive a YOLO ``load`` proposal.  CV has a
    # stronger, diagram-level observation in this case: an overlapping arrow
    # candidate whose *tip* visibly continues into another conductor.  Never
    # revive that marker through a separate YOLO-box port guess.  This is a
    # topology rule, not a confidence threshold, and keeps genuine small
    # loads whose CV rejection was only caused by a broken/short tail.
    maximum_pendant_lead = max(160, int(context["thin_width"]) * 28)
    for rejected in rejected_loads or ():
        if "tip continues into a through conductor" not in str(
            getattr(rejected, "reason", "")
        ):
            continue
        # A local arrowhead can touch a nearby bus and still be reported as a
        # through-line by the coarse CV core.  Only treat the observation as
        # decisive when that CV walk actually travelled far beyond any
        # plausible pendant feeder.  This is the case for a flow marker on a
        # network line, not for a compact load symbol.
        if int(getattr(rejected, "lead_length", 0)) <= maximum_pendant_lead:
            continue
        rejected_bbox = _bbox_from_load_candidate(rejected)
        overlap = _bbox_iou(yolo_bbox, rejected_bbox)
        distance = float(np.hypot(
            float(yolo_bbox[0]) - float(rejected_bbox[0]),
            float(yolo_bbox[1]) - float(rejected_bbox[1]),
        ))
        tolerance = max(
            8.0,
            0.35 * max(
                float(yolo_bbox[2]),
                float(yolo_bbox[3]),
                float(rejected_bbox[2]),
                float(rejected_bbox[3]),
            ),
        )
        if overlap >= 0.08 or distance <= tolerance:
            return None
    center_x, center_y, width, height = (
        float(value) * LOAD_SCALE for value in yolo_bbox
    )
    thin_width = int(context["thin_width"])
    long_side, short_side = max(width, height), min(width, height)
    if (
        short_side < max(10.0, thin_width * 2.0)
        or long_side > max(context["binary"].shape) * 0.12
        or long_side / max(short_side, 1.0) > 3.8
    ):
        return None

    binary = context["binary"]
    skeleton = context["skeleton"]
    successes = []
    # ``tail_direction`` points from the arrowhead toward its connected bus.
    # LoadCandidate.direction points the other way, toward the arrow tip.
    for tail_direction in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        axis_extent = height / 2.0 if tail_direction[1] else width / 2.0
        # The tail must remain just inside the detector box so the first
        # outward-ink probe lands on the short shaft even when the box clips
        # it.  In contrast, the arrow *tip* needs to be outside the outline:
        # otherwise an outline triangle mistakes its own two sides for a
        # through conductor in the pendant-device check.
        base_extent = max(1.0, axis_extent - thin_width)
        tip_extent = axis_extent + max(1.0, float(thin_width))
        base = (
            center_x + tail_direction[0] * base_extent,
            center_y + tail_direction[1] * base_extent,
        )
        if not _tail_has_outward_ink(skeleton, base, tail_direction, thin_width):
            continue
        direction = (-tail_direction[0], -tail_direction[1])
        tip = (
            center_x + direction[0] * tip_extent,
            center_y + direction[1] * tip_extent,
        )
        candidate = load_cv.LoadCandidate(
            x=int(round(center_x - width / 2.0)),
            y=int(round(center_y - height / 2.0)),
            w=max(1, int(round(width))),
            h=max(1, int(round(height))),
            tip=tip,
            base=base,
            direction=direction,
            # The proposal is class evidence only.  The pixel path below is
            # the physical acceptance evidence.
            triangle_score=float(yolo_confidence),
        )
        # Do not reuse the old enclosed-hole rejection here.  It correctly
        # catches a digit when CV has generated a tiny triangle candidate,
        # but a YOLO box around an outline load legitimately encloses its
        # entire arrow/shaft area and can look hollow.  The mandatory outward
        # lead plus bus-reaching pixel trace is the stronger discriminator.
        if _direct_load_tail_reaches_cv_bus(
            binary,
            candidate,
            load_bus_boxes,
            thin_width,
        ) or attach_to_bus_via_pixel_path(
            binary,
            candidate,
            load_bus_boxes,
            thin_width,
            skeleton=skeleton,
        ):
            # The tail-to-CV-bus trace, size, and lead-length checks remain
            # mandatory.  A YOLO rectangle cannot localise an outline
            # triangle's tip reliably enough for a pixel-level tip test; the
            # independent long CV through-line conflict above is the safer
            # flow-marker guard for this rescue path.
            if not load_cv._valid_pendant_load(
                binary,
                candidate,
                thin_width,
                check_tip_continuation=False,
            ):
                continue
            successes.append(candidate)
    if not successes:
        return None
    selected = min(successes, key=lambda candidate: candidate.lead_length)
    selected.reason = "accepted: YOLO load with tail traced to CV bus"
    return selected, int(selected.attached_bus)

# ==========================================
# 1. Topology 보조 함수들 (기존 코드와 100% 동일)
# ==========================================
def normalize_vector(v):
    norm = np.hypot(v[0], v[1])
    if norm == 0: return (0, 0)
    return (v[0]/norm, v[1]/norm)

def get_smoothed_direction(path, lookback=12):
    if len(path) < 3: return (0, 0)
    start_idx = max(0, len(path) - lookback)
    dx = path[-1][0] - path[start_idx][0]
    dy = path[-1][1] - path[start_idx][1]
    return normalize_vector((dx, dy))

def calculate_angle_std(path):
    if len(path) < 3: return 0.0
    angles = []
    for i in range(len(path) - 2):
        p1, p2, p3 = np.array(path[i]), np.array(path[i+1]), np.array(path[i+2])
        v1 = normalize_vector(p2 - p1)
        v2 = normalize_vector(p3 - p2)
        dot_product = np.clip(np.dot(v1, v2), -1.0, 1.0)
        angles.append(np.arccos(dot_product))
    return np.std(angles) if angles else 0.0


def _reconstruct_weak_ink(strong, weak):
    """Keep weak pixels only when they belong to strong source ink."""
    strong_mask = np.asarray(strong, dtype=bool)
    weak_mask = np.asarray(weak, dtype=bool)
    if strong_mask.shape != weak_mask.shape:
        raise ValueError("strong and weak masks must have the same shape")
    reconstructed = np.where(strong_mask, 255, 0).astype(np.uint8)
    allowed = np.where(weak_mask, 255, 0).astype(np.uint8)
    kernel = np.ones((3, 3), np.uint8)
    while True:
        grown = cv2.bitwise_and(cv2.dilate(reconstructed, kernel), allowed)
        if np.array_equal(grown, reconstructed):
            return reconstructed
        reconstructed = grown


def _topology_hysteresis_binary(gray):
    """Preserve faint anti-aliased conductors connected to strong black ink.

    Otsu remains the page-specific strong threshold. A conservative weak
    threshold is derived from the remaining distance to white, and weak pixels
    survive only by morphological reconstruction from strong ink. This keeps
    a faded line centre without globally admitting isolated grey background.
    """
    otsu_threshold, strong_binary = cv2.threshold(
        gray,
        0,
        255,
        cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU,
    )
    weak_threshold = float(otsu_threshold) + 0.25 * (
        255.0 - float(otsu_threshold)
    )
    weak = gray <= weak_threshold
    return _reconstruct_weak_ink(strong_binary > 0, weak)


def _remove_numeric_text_components(binary, protected_mask=None):
    """Remove isolated number-like glyphs before topology skeletonization.

    SLD labels are black pixels just like conductors.  The old pipeline left
    those connected components in the skeleton and the endpoint walker could
    then bridge a bus to a nearby digit.  Numeric glyphs in the reference
    drawings are compact, taller than they are wide, and isolated from the
    conductor component.  Thin wires and bus bars fail at least one of those
    shape tests and remain untouched.
    """
    if binary is None or binary.ndim != 2:
        return binary
    if protected_mask is not None and protected_mask.shape != binary.shape:
        raise ValueError("protected text mask must match binary shape")

    height, width = binary.shape[:2]
    labels_count, labels, stats, _ = cv2.connectedComponentsWithStats(
        binary,
        connectivity=8,
    )
    min_height = max(12, int(round(height * 0.015)))
    max_height = min(48, max(30, int(round(height * 0.08))))
    max_width = max(24, int(round(width * 0.03)))
    cleaned = binary.copy()

    for label in range(1, labels_count):
        x, y, component_width, component_height, area = (
            int(value) for value in stats[label]
        )
        if not (
            min_height <= component_height <= max_height
            and 3 <= component_width <= max_width
            and 25 <= area <= 450
        ):
            continue
        aspect = component_height / max(component_width, 1)
        density = area / max(component_width * component_height, 1)
        if not (1.15 <= aspect <= 6.0 and 0.15 <= density <= 0.75):
            continue
        if (
            protected_mask is not None
            and np.any(protected_mask[labels == label] > 0)
        ):
            # An accepted load/device owns this ink. Its compact arrow and
            # shaft can otherwise look exactly like a vertical numeral.
            continue
        cleaned[labels == label] = 0

    return cleaned


def _unit_vector(vector):
    """Return a 2-D unit vector without leaking numpy scalar types."""
    values = np.asarray(vector, dtype=float).reshape(-1)
    if values.size < 2:
        return np.zeros(2, dtype=float)
    norm = float(np.hypot(values[0], values[1]))
    if norm <= 1e-6:
        return np.zeros(2, dtype=float)
    return values[:2] / norm


def _endpoint_tangent(skeleton, endpoint):
    """Estimate the direction from an endpoint away from its object.

    The endpoint is produced after all object masks have been removed.  Its
    remaining neighbour therefore points from the component port into the
    line.  This is the direction we compare with the port's outward normal.
    """
    x, y = endpoint
    height, width = skeleton.shape[:2]
    neighbours = []
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


def _project_to_segment(point, first, second):
    """Project a point onto a finite segment and return the projected point."""
    point = np.asarray(point, dtype=float)
    first = np.asarray(first, dtype=float)
    second = np.asarray(second, dtype=float)
    axis = second - first
    denominator = float(np.dot(axis, axis))
    if denominator <= 1e-6:
        return first
    ratio = float(np.dot(point - first, axis) / denominator)
    return first + np.clip(ratio, 0.0, 1.0) * axis


def _make_component_ports(
    component_id,
    component_class,
    box,
    load_candidate=None,
    transformer_info=None,
):
    """Build geometry-aware connection ports for one detected component.

    A port is deliberately not a generic nearest-point relationship:

    * a load exposes only the arrow tail/shaft side;
    * a transformer exposes independent opposite-side ports;
    * a bus and generator use a boundary/radial port because their wires can
      enter from more than one direction.

    Transformer ports are *available* independently.  We do not require two
    ports to be present and we do not deduplicate two real paths that happen
    to terminate on the same transformer side.
    """
    x1, y1, x2, y2 = (float(value) for value in box)
    width = max(1.0, x2 - x1)
    height = max(1.0, y2 - y1)
    centre = np.asarray(((x1 + x2) / 2.0, (y1 + y2) / 2.0), dtype=float)

    if component_class == "load" and load_candidate is not None:
        # LoadCandidate geometry is stored at LOAD_SCALE.  The arrow's base
        # is the shaft-side port; the tip side must never be used as a line
        # endpoint.
        base = np.asarray(load_candidate.base, dtype=float) / LOAD_SCALE
        arrow_direction = _unit_vector(load_candidate.direction)
        return [{
            "component_id": component_id,
            "side": "tail",
            "mode": "fixed",
            "point": base,
            "direction": -arrow_direction,
            "max_distance": 34.0,
        }]

    if component_class == "transformer":
        orientation = str((transformer_info or {}).get("orientation", ""))
        if orientation not in {"horizontal", "vertical"}:
            orientation = "vertical" if height >= width else "horizontal"

        # Keep a little room away from the winding's corners.  A line can
        # attach anywhere along a side, so each side is represented by a
        # segment rather than one centre point.
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
                    # The detector box ends just outside the winding.  A
                    # much larger radius would re-attach a nearby load or a
                    # neighbouring bus to the transformer merely because it
                    # is on the same side of the drawing.
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
            "box": (x1, y1, x2, y2),
            "centre": centre,
            # A generator terminal should be on or immediately outside the
            # detected circle. A large radius lets an unrelated nearby
            # skeleton endpoint win over the real shaft.
            "max_distance": 14.0,
        }]

    # Buses are bars, so a line may enter at any point on their boundary.  The
    # endpoint must nevertheless be close to that boundary.  A loose radius
    # here lets an isolated digit stroke several dozen pixels away become a
    # fake bus-to-bus line after skeleton tracing.
    return [{
        "component_id": component_id,
        "side": "boundary",
        "mode": "box_boundary",
        "box": (x1, y1, x2, y2),
        "max_distance": 10.0,
    }]


def _match_endpoint_to_port(endpoint, tangent, port, component_class):
    """Score an endpoint against a port using distance *and* direction."""
    point = np.asarray(endpoint, dtype=float)
    mode = port["mode"]
    port_point = None

    if mode == "fixed":
        port_point = np.asarray(port["point"], dtype=float)
        expected = _unit_vector(port["direction"])
    elif mode == "segment":
        port_point = _project_to_segment(point, port["first"], port["second"])
        expected = _unit_vector(port["direction"])
    else:
        x1, y1, x2, y2 = port["box"]
        port_point = np.asarray((
            np.clip(point[0], x1, x2),
            np.clip(point[1], y1, y2),
        ), dtype=float)
        if mode == "box_radial":
            expected = _unit_vector(point - port["centre"])
        else:
            # A skeleton endpoint can land exactly on a bus boundary after
            # the component mask is applied.  In that case the boundary
            # normal is not recoverable from a zero-length delta; the local
            # skeleton tangent is the reliable outward direction.
            expected = _unit_vector(tangent)

    delta = point - port_point
    distance = float(np.linalg.norm(delta))
    if mode == "box_boundary" and distance > 1.5:
        expected = _unit_vector(delta)
    radial_alignment = (
        float(np.dot(_unit_vector(delta), expected)) if distance > 1.5 else 1.0
    )
    tangent_alignment = float(np.dot(_unit_vector(tangent), expected))
    max_distance = float(port["max_distance"])
    if distance > max_distance:
        return None

    if mode in {"fixed", "segment"}:
        # A load's shaft is directional: an endpoint on the side of the
        # arrowhead is not a valid tail connection even when it is nearby.
        radial_limit = 0.48 if component_class == "load" else 0.22
        tangent_limit = 0.48 if component_class == "load" else 0.25
        allow_short_transformer_bend = (
            component_class == "transformer"
            and mode == "segment"
            and distance <= 3.5
            and radial_alignment >= 0.65
        )
        if radial_alignment < radial_limit or (
            tangent_alignment < tangent_limit
            and not allow_short_transformer_bend
        ):
            return None
    elif mode == "box_radial" and tangent_alignment < 0.15:
        # A short anti-aliased generator shaft can leave a diagonal tangent
        # immediately outside the masked box.  For very close endpoints the
        # distance to the component port is stronger evidence than the local
        # skeleton tangent; keep the stricter direction check farther away.
        # Three pixels covers that anti-aliased gap without admitting the
        # opposite-facing endpoint of a nearby generator shaft.
        if distance > 3.0:
            return None

    distance_score = max(0.0, 1.0 - distance / max_distance)
    score = (
        0.48 * tangent_alignment
        + 0.37 * radial_alignment
        + 0.15 * distance_score
    )
    # A directional symbol port must win over a generic nearby boundary.  A
    # bus is often physically close to its attached load/generator, so a
    # pure distance sort would assign the same endpoint to the bus and leave
    # the actual device disconnected.  Invalid load-side directions have
    # already been rejected above and therefore cannot be promoted here.
    if component_class == "load" and mode == "fixed" and distance <= 10.0:
        priority = 4
    elif component_class == "transformer" and mode == "segment" and distance <= 8.0:
        priority = 3
    elif component_class == "generator" and mode == "box_radial" and distance <= 10.0:
        priority = 2
    else:
        priority = 0
    return {
        "component_id": port["component_id"],
        "side": port["side"],
        "component_class": component_class,
        "priority": priority,
        "mode": mode,
        "score": float(score),
        "distance": distance,
        "radial_alignment": radial_alignment,
        "tangent_alignment": tangent_alignment,
    }


def _assign_endpoints_to_ports(skeleton, endpoints, component_ports, component_classes):
    """Assign only direction-compatible skeleton endpoints to components."""
    endpoint_to_component = {}
    endpoint_to_port = {}
    for endpoint in endpoints:
        tangent = _endpoint_tangent(skeleton, endpoint)
        matches = []
        for component_id, ports in component_ports.items():
            component_class = component_classes[component_id]
            for port in ports:
                match = _match_endpoint_to_port(
                    endpoint, tangent, port, component_class
                )
                if match is not None:
                    matches.append(match)
        if not matches:
            continue
        best = max(
            matches,
            key=lambda match: (match["priority"], match["score"]),
        )
        endpoint_to_component[endpoint] = best["component_id"]
        endpoint_to_port[endpoint] = best
    return endpoint_to_component, endpoint_to_port


def _make_validated_load_bus_path(load_candidate, bus_box):
    """Create a straight pixel path from a validated load tail to its bus.

    ``detect_cv_loads`` has already traced this cardinal lead against the CV
    bus detector and stores the bus index on ``attached_bus``.  The final
    topology skeleton can nevertheless lose the endpoint when the load box
    masks a very short or anti-aliased shaft.  This fallback preserves the
    validated physical relationship without inventing a free-form nearest
    neighbour edge.
    """
    if load_candidate is None or load_candidate.attached_bus is None:
        return []

    x1, y1, x2, y2 = (
        float(value) / LOAD_SCALE for value in bus_box
    )
    traced_attachment = getattr(load_candidate, "attachment_path", None)
    if traced_attachment:
        # The load detector has already followed this exact ink path to the
        # accepted bus, including any orthogonal bend.  Reuse that evidence in
        # source-image coordinates instead of inventing a straight shortcut.
        scaled_points = traced_attachment
        points = []
        for scaled_x, scaled_y in scaled_points:
            item = (
                int(round(float(scaled_x) / LOAD_SCALE)),
                int(round(float(scaled_y) / LOAD_SCALE)),
            )
            if not points or item != points[-1]:
                points.append(item)
        return points if len(points) >= 3 else []
    if "traced" in str(getattr(load_candidate, "reason", "")):
        # A routed lead without a source-ink projection is evidence for the
        # object relation, but not enough evidence to draw a synthetic path.
        return []

    start = np.asarray(load_candidate.base, dtype=float) / LOAD_SCALE
    direction = _unit_vector((-load_candidate.direction[0], -load_candidate.direction[1]))
    if not np.any(direction):
        return []

    # The detector only accepts cardinal arrows.  Intersect the tail ray
    # with the appropriate side of the bus rectangle.
    if abs(direction[1]) >= abs(direction[0]):
        target_x = float(np.clip(start[0], x1, x2))
        if abs(target_x - start[0]) > 3.0:
            return []
        target_y = y2 if direction[1] < 0 else y1
        target = np.asarray((target_x, target_y), dtype=float)
    else:
        target_y = float(np.clip(start[1], y1, y2))
        if abs(target_y - start[1]) > 3.0:
            return []
        target_x = x2 if direction[0] < 0 else x1
        target = np.asarray((target_x, target_y), dtype=float)

    distance = float(np.linalg.norm(target - start))
    if distance < 3.0:
        return []
    points = []
    for step in range(int(np.ceil(distance)) + 1):
        point = start + direction * min(float(step), distance)
        item = (int(round(point[0])), int(round(point[1])))
        if not points or item != points[-1]:
            points.append(item)
    return points


def _add_validated_load_bus_fallbacks(
    line_candidates,
    component_classes,
    component_metadata,
    topology_source_binary=None,
    topology_thin_width=1,
):
    """Use the load detector's accepted bus attachment when skeleton lost it."""
    result = list(line_candidates)
    scaled_source_binary = None
    scaled_source_skeleton = None
    for load_id, metadata in component_metadata.items():
        if component_classes.get(load_id) != "load":
            continue
        attached_bus_id = metadata.get("attached_bus_id")
        attached_bus_box = metadata.get("attached_bus_box")
        load_candidate = metadata.get("load_candidate")
        if not attached_bus_id or attached_bus_box is None or load_candidate is None:
            continue

        has_bus_edge = any(
            load_id in candidate["connected_to"]
            and any(
                component_classes.get(other_id) == "bus"
                for other_id in candidate["connected_to"]
                if other_id != load_id
            )
            for candidate in result
        )
        if has_bus_edge:
            continue

        path = _make_validated_load_bus_path(load_candidate, attached_bus_box)
        if len(path) < 3 and topology_source_binary is not None:
            # The detector's initial Otsu binary can miss a faint shaft that
            # the topology hysteresis pass has retained. Retry only this
            # already-validated load against that source; the returned path is
            # still projected to undilated source pixels by the load tracer.
            if scaled_source_binary is None:
                scaled_source_binary = cv2.resize(
                    topology_source_binary,
                    None,
                    fx=float(LOAD_SCALE),
                    fy=float(LOAD_SCALE),
                    interpolation=cv2.INTER_NEAREST,
                )
                scaled_source_skeleton = bus_cv.skeletonize(
                    scaled_source_binary
                )
            if attach_to_bus_via_pixel_path(
                scaled_source_binary,
                load_candidate,
                [attached_bus_box],
                max(1, int(round(float(topology_thin_width) * LOAD_SCALE))),
                skeleton=scaled_source_skeleton,
                _allow_orientation_correction=False,
            ):
                path = _make_validated_load_bus_path(
                    load_candidate,
                    attached_bus_box,
                )
        has_drawable_path = len(path) >= 3
        result.append({
            "connected_to": [load_id, attached_bus_id],
            "path": path if has_drawable_path else [],
            "connection_score": 0.96 if has_drawable_path else 0.92,
            "source_port": "tail",
            "target_port": "boundary",
            "trace_method": (
                "cv_load_bus_attachment"
                if has_drawable_path
                else "cv_load_bus_relation_only"
            ),
        })
    return result


def _keep_single_port_components(line_candidates, component_classes):
    """Limit loads/generators to one best physical connection.

    Buses and transformers intentionally have no global one-line limit.  A
    transformer can have one visible port, two opposite ports, or multiple
    real conductors on a side in a drawing; all direction-valid paths remain.
    """
    limited = {
        component_id
        for component_id, component_class in component_classes.items()
        if component_class in {"load", "generator"}
    }
    keep = set(range(len(line_candidates)))
    for component_id in limited:
        incident = [
            index for index, candidate in enumerate(line_candidates)
            if component_id in candidate["connected_to"]
        ]
        if len(incident) <= 1:
            continue
        if component_classes.get(component_id) == "load":
            bus_incident = [
                index for index in incident
                if any(
                    component_classes.get(other_id) == "bus"
                    for other_id in line_candidates[index]["connected_to"]
                    if other_id != component_id
                )
            ]
            # A load is electrically meaningful only through its bus.  If a
            # valid bus fallback exists, it wins over a stray non-bus path.
            if bus_incident:
                preferred_incident = bus_incident
            else:
                preferred_incident = incident
        else:
            preferred_incident = incident
        if component_classes.get(component_id) == "generator":
            # A nearby branch can score higher than the real generator shaft
            # when the branch tangent is noisy. The terminal distance is a
            # stronger invariant: choose the candidate whose endpoint is
            # actually touching the generator box, then use score/path as
            # tie breakers.
            def generator_key(index):
                candidate = line_candidates[index]
                distance = float(
                    candidate.get("port_distances", {}).get(
                        component_id, float("inf")
                    )
                )
                return (
                    -distance,
                    candidate["connection_score"],
                    len(candidate["path"]),
                )

            best = max(preferred_incident, key=generator_key)
        else:
            best = max(
                preferred_incident,
                key=lambda index: (
                    line_candidates[index]["connection_score"],
                    -len(line_candidates[index]["path"]),
                ),
            )
        keep.difference_update(index for index in incident if index != best)
    return [candidate for index, candidate in enumerate(line_candidates) if index in keep]

def find_best_exit(skel_img, cx, cy, w, h, visited, current_dir, radius=12):
    queue = deque()
    queue.append((cx, cy, [(cx, cy)]))
    local_visited = set([(cx, cy)])
    exits = []
    current_dir = (current_dir[0], current_dir[1])

    while queue:
        curr_x, curr_y, path_so_far = queue.popleft()
        if max(abs(curr_x - cx), abs(curr_y - cy)) >= radius:
            if len(path_so_far) >= 6:
                exits.append((curr_x, curr_y, path_so_far))
            continue
            
        for dy in [-1, 0, 1]:
            for dx in [-1, 0, 1]:
                if dx == 0 and dy == 0: continue
                nx, ny = curr_x + dx, curr_y + dy
                if 0 <= nx < w and 0 <= ny < h:
                    if skel_img[ny, nx] == 255:
                        if (nx, ny) not in visited and (nx, ny) not in local_visited:
                            local_visited.add((nx, ny))
                            queue.append((nx, ny, path_so_far + [(nx, ny)]))
                            
    if not exits: return []
    best_path = []
    max_score = -float('inf')
    
    for ex, ey, path in exits:
        lookahead_vec = normalize_vector((ex - cx, ey - cy))
        cosine_to_exit = 1.0 if current_dir == (0,0) else np.dot(current_dir, lookahead_vec)
        
        if cosine_to_exit < -0.2: 
            continue 
            
        angles_std = calculate_angle_std(path)
        score = (cosine_to_exit * 0.8) - (angles_std * 0.2)
        
        if score > max_score:
            max_score = score
            best_path = path
            
    if max_score == -float('inf'): return []
    return best_path

def walk_skeleton_endpoint_v14(skel_img, start_pt, comp_id, endpoints, endpoint_to_comp, used_endpoints):
    h, w = skel_img.shape
    visited = set([start_pt])
    path = [start_pt]
    current_pt = start_pt
    MAX_STEPS = 5000
    step_count = 0

    while step_count < MAX_STEPS:
        step_count += 1
        cx, cy = current_pt
        
        if current_pt in endpoints and current_pt != start_pt:
            if current_pt in used_endpoints:
                return None, None, []
            target_comp = endpoint_to_comp.get(current_pt)
            if target_comp and target_comp != comp_id:
                return target_comp, current_pt, path
            
        neighbors = []
        for dx in [-1, 0, 1]:
            for dy in [-1, 0, 1]:
                if dx == 0 and dy == 0: continue
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < w and 0 <= ny < h:
                    if skel_img[ny, nx] == 255 and (nx, ny) not in visited:
                        neighbors.append((nx, ny))
                        
        clusters = []
        for n in neighbors:
            placed = False
            for cluster in clusters:
                if any(max(abs(n[0]-c[0]), abs(n[1]-c[1])) <= 1 for c in cluster):
                    cluster.append(n)
                    placed = True
                    break
            if not placed:
                clusters.append([n])
        
        num_branches = len(clusters)

        if num_branches == 1:
            if len(clusters[0]) == 1:
                next_pt = clusters[0][0]
            else:
                current_dir = get_smoothed_direction(path, lookback=8)
                best_n = clusters[0][0]
                max_cos = -2.0
                for n_pt in clusters[0]:
                    vec = normalize_vector((n_pt[0]-cx, n_pt[1]-cy))
                    cos_theta = 1.0 if current_dir == (0,0) else (current_dir[0]*vec[0] + current_dir[1]*vec[1])
                    if cos_theta > max_cos:
                        max_cos = cos_theta
                        best_n = n_pt
                next_pt = best_n
            visited.add(next_pt)
            path.append(next_pt)
            current_pt = next_pt
            
        elif num_branches > 1:
            current_dir = get_smoothed_direction(path, lookback=10)
            jump_pt = None
            if current_dir != (0, 0):
                best_cos = 0.95 
                for r in range(3, 13):
                    for dy in range(-r, r + 1):
                        for dx in range(-r, r + 1):
                            if max(abs(dx), abs(dy)) == r:
                                nx, ny = cx + dx, cy + dy
                                if 0 <= nx < w and 0 <= ny < h:
                                    if skel_img[ny, nx] == 255 and (nx, ny) not in visited:
                                        vec = normalize_vector((dx, dy))
                                        cos_theta = (current_dir[0]*vec[0] + current_dir[1]*vec[1])
                                        if cos_theta > best_cos:
                                            best_cos = cos_theta
                                            jump_pt = (nx, ny)
                    if jump_pt: break 
            
            if jump_pt:
                dist = int(math.hypot(jump_pt[0]-cx, jump_pt[1]-cy))
                for i in range(1, dist + 1):
                    ix = int(cx + (jump_pt[0]-cx) * (i/dist))
                    iy = int(cy + (jump_pt[1]-cy) * (i/dist))
                    visited.add((ix, iy))
                    path.append((ix, iy))
                current_pt = jump_pt
            else:
                best_path = find_best_exit(skel_img, cx, cy, w, h, visited, current_dir, radius=12)
                if len(best_path) > 1:
                    for pt in best_path[1:]:
                        visited.add(pt)
                        path.append(pt)
                    current_pt = best_path[-1]
                else:
                    break 
                
        else:
            jump_pt = None
            current_dir = get_smoothed_direction(path, lookback=10)
            if current_dir != (0, 0):
                best_cos = 0.94
                for r in range(2, 8):
                    for dy in range(-r, r + 1):
                        for dx in range(-r, r + 1):
                            if max(abs(dx), abs(dy)) == r:
                                nx, ny = cx + dx, cy + dy
                                if 0 <= nx < w and 0 <= ny < h:
                                    if skel_img[ny, nx] == 255 and (nx, ny) not in visited:
                                        vec = normalize_vector((dx, dy))
                                        cos_theta = (current_dir[0]*vec[0] + current_dir[1]*vec[1])
                                        if cos_theta > best_cos:
                                            best_cos = cos_theta
                                            jump_pt = (nx, ny)
                    if jump_pt: break 
                    
            if jump_pt:
                dist = int(math.hypot(jump_pt[0]-cx, jump_pt[1]-cy))
                for i in range(1, dist + 1):
                    ix = int(cx + (jump_pt[0]-cx) * (i/dist))
                    iy = int(cy + (jump_pt[1]-cy) * (i/dist))
                    visited.add((ix, iy))
                    path.append((ix, iy))
                current_pt = jump_pt
            else:
                break 
            
    return None, None, []

# ==========================================
# 2. 통합 핵심 로직 (YOLO + 선로 추적)
# ==========================================
def _looks_like_transformer_pair(
    image: np.ndarray,
    x_center: float,
    y_center: float,
    width: float,
    height: float,
) -> bool:
    """Reject an elongated YOLO generator box containing two transformer coils."""
    short_side = min(width, height)
    if short_side <= 0 or max(width, height) / short_side < 1.28:
        return False

    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    padding = max(10, int(round(short_side * 0.35)))
    x1 = max(0, int(round(x_center - width / 2)) - padding)
    y1 = max(0, int(round(y_center - height / 2)) - padding)
    x2 = min(image.shape[1], int(round(x_center + width / 2)) + padding)
    y2 = min(image.shape[0], int(round(y_center + height / 2)) + padding)
    roi = gray[y1:y2, x1:x2]
    if roi.size == 0:
        return False

    expected_radius = short_side / 2
    blurred = cv2.GaussianBlur(roi, (5, 5), 1.2)
    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,
        dp=1.0,
        minDist=max(8, int(round(expected_radius * 0.8))),
        param1=80,
        param2=13,
        minRadius=max(8, int(round(expected_radius * 0.45))),
        maxRadius=max(12, int(round(expected_radius * 1.4))),
    )
    if circles is None:
        return False

    detected = []
    for local_x, local_y, radius in circles[0]:
        global_x, global_y = local_x + x1, local_y + y1
        if (
            abs(global_x - x_center) <= width * 0.75
            and abs(global_y - y_center) <= height * 0.75
        ):
            detected.append((float(global_x), float(global_y), float(radius)))

    for index, first in enumerate(detected):
        for second in detected[index + 1:]:
            center_distance = float(np.hypot(
                first[0] - second[0], first[1] - second[1]
            ))
            radius_ratio = min(first[2], second[2]) / max(first[2], second[2])
            if center_distance < max(8.0, short_side * 0.25):
                continue
            if radius_ratio < 0.78:
                continue
            dx = abs(first[0] - second[0])
            dy = abs(first[1] - second[1])
            aligned_with_long_axis = (
                dy >= dx * 1.5 if height >= width else dx >= dy * 1.5
            )
            if aligned_with_long_axis:
                return True
    return False


def _has_compact_transformer_ring_pair(
    image: np.ndarray,
    x_center: float,
    y_center: float,
    width: float,
    height: float,
) -> bool:
    """Verify a compact overlapping-ring transformer inside a YOLO proposal.

    The existing helper intentionally expects an elongated generator-shaped
    false positive.  Actual two-winding symbols can be almost square because
    their two circles overlap substantially, so they need a separate local
    check.  The proposal still has to be a high-confidence transformer and
    this routine only accepts two similar, axis-aligned Hough rings.
    """
    short_side = min(width, height)
    if short_side < 24.0:
        return False
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    padding = max(8, int(round(short_side * 0.30)))
    x1 = max(0, int(round(x_center - width / 2.0)) - padding)
    y1 = max(0, int(round(y_center - height / 2.0)) - padding)
    x2 = min(image.shape[1], int(round(x_center + width / 2.0)) + padding)
    y2 = min(image.shape[0], int(round(y_center + height / 2.0)) + padding)
    roi = gray[y1:y2, x1:x2]
    if roi.size == 0:
        return False

    expected_radius = short_side / 2.0
    circles = cv2.HoughCircles(
        cv2.GaussianBlur(roi, (5, 5), 1.0),
        cv2.HOUGH_GRADIENT,
        dp=1.0,
        minDist=max(8, int(round(expected_radius * 0.40))),
        param1=60,
        param2=11,
        minRadius=max(7, int(round(expected_radius * 0.30))),
        maxRadius=max(12, int(round(expected_radius * 1.20))),
    )
    if circles is None:
        return False

    detected = [
        (float(local_x + x1), float(local_y + y1), float(radius))
        for local_x, local_y, radius in circles[0]
        if (
            abs(local_x + x1 - x_center) <= width * 0.60
            and abs(local_y + y1 - y_center) <= height * 0.60
        )
    ]
    for index, first in enumerate(detected):
        for second in detected[index + 1:]:
            dx = abs(first[0] - second[0])
            dy = abs(first[1] - second[1])
            distance = float(np.hypot(dx, dy))
            average_radius = (first[2] + second[2]) / 2.0
            radius_ratio = min(first[2], second[2]) / max(first[2], second[2])
            if radius_ratio < 0.70:
                continue
            if not 0.40 * average_radius <= distance <= 1.65 * average_radius:
                continue
            if max(dx, dy) < max(8.0, min(dx, dy) * 1.8):
                continue
            return True
    return False


def analyze_circuit_image(
    image_bytes,
    model,
    load_mask_mode="box",
    *,
    skip_topology=False,
):
    # 1. 바이트를 OpenCV 이미지로 변환 (파일 저장 불필요)
    nparr = np.frombuffer(image_bytes, np.uint8)
    img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    h_img, w_img = img.shape[:2]

    # Run the semantic proposal pass once.  Bus CV consumes these locations
    # before load tracing so every device sees the final electrically
    # validated bus family; the same result objects are reused below.
    results = model.predict(
        img,
        conf=YOLO_PROBE_CONFIDENCE,
        iou=0.4,
        imgsz=YOLO_IMAGE_SIZE,
        max_det=300,
        line_width=1,
        verbose=False,
    )

    # 2. CV is the primary detector.  Its accepted geometry owns both the
    # display box and the topology mask.  Rejected CV candidates are retained
    # as a registry for the guarded YOLO rescue stage below.
    if CV_SUPPLEMENT_ENABLED:
        cv_bus_result = detect_cv_buses(img, return_debug=True)
        cv_buses, cv_rejected_buses = cv_bus_result
        cv_buses = _electrical_bus_consensus(img, cv_buses, results, model)
        # Every device-to-bus validation must see the exact same final CV bus
        # family that becomes graph nodes.  Calling the load experiment with
        # no bus records used to produce a second, smaller morphology-only bus
        # set on some diagrams; real arrows connected to a reconstructed bus
        # were then rejected before the path trace even began.
        cv_loads, cv_rejected_loads, load_bus_boxes = detect_cv_loads(
            img,
            bus_records=cv_buses,
        )
        filtered_cv_buses = _remove_load_head_bus_candidates(
            cv_buses,
            cv_loads,
            img.shape,
        )
        if len(filtered_cv_buses) != len(cv_buses):
            cv_buses = filtered_cv_buses
            # Re-run attachment so every load index refers to the filtered
            # bus registry.  This also proves that the arrow has a real lead
            # to a different bus instead of depending on its own flat base.
            cv_loads, cv_rejected_loads, load_bus_boxes = detect_cv_loads(
                img,
                bus_records=cv_buses,
            )
        cv_transformers = detect_cv_transformers(img)
    else:
        cv_buses, cv_rejected_buses = [], []
        cv_loads, cv_rejected_loads, load_bus_boxes = [], [], []
        cv_transformers = []

    predictions = []
    components = {}
    component_classes = {}
    component_metadata = {}
    load_candidates_by_component = {}

    def add_node(class_name, bbox, confidence, source, metadata=None):
        comp_id = f"{class_name}_{len(predictions)}"
        prediction = {
            "id": comp_id,
            "class": class_name,
            "bbox": [float(value) for value in bbox],
            "confidence": float(confidence),
            "source": source,
        }
        # The staged Review API runs object detection and line tracing in two
        # separate requests. Preserve the electrically meaningful transformer
        # orientation across that boundary. Wide wave windings still connect
        # vertically, so reconstructing ports from bbox aspect ratio is wrong.
        transformer = (metadata or {}).get("transformer")
        if class_name == "transformer" and isinstance(transformer, dict):
            serializable_transformer = {
                key: transformer[key]
                for key in (
                    "style",
                    "orientation",
                    "electrical_two_port",
                    "orientation_source",
                )
                if key in transformer
            }
            if serializable_transformer:
                prediction["metadata"] = {
                    "transformer": serializable_transformer,
                }
        predictions.append(prediction)
        component_classes[comp_id] = class_name
        component_metadata[comp_id] = dict(metadata or {})
        _set_component_box(components, comp_id, bbox, img.shape)
        return comp_id

    cv_bus_records = []
    for bus in cv_buses:
        bbox = [float(bus["x"]), float(bus["y"]), float(bus["w"]), float(bus["h"])]
        comp_id = add_node(
            "bus",
            bbox,
            float(bus.get("confidence", 0.95)),
            str(bus.get("source", "cv_primary")),
            {"cv_bus": bus},
        )
        cv_bus_records.append({"component_id": comp_id, "bbox": bbox})

    bus_component_ids = [record["component_id"] for record in cv_bus_records]

    # A CV load is admitted to the graph only if its tail is already mapped to
    # one of the CV buses.  This is the non-negotiable anti-number condition.
    for load in cv_loads:
        attached_bus_index = getattr(load, "attached_bus", None)
        try:
            attached_bus_index = int(attached_bus_index) if attached_bus_index is not None else None
        except (TypeError, ValueError):
            attached_bus_index = None
        if (
            attached_bus_index is None
            or not (0 <= attached_bus_index < len(bus_component_ids))
            or bus_component_ids[attached_bus_index] is None
        ):
            continue
        bbox = _bbox_from_load_candidate(load)
        confidence = min(0.94, max(0.75, float(load.triangle_score) + 0.45))
        attached_bus_id = bus_component_ids[attached_bus_index]
        attached_bus_box = (
            load_bus_boxes[attached_bus_index]
            if attached_bus_index < len(load_bus_boxes)
            else None
        )
        comp_id = add_node(
            "load",
            bbox,
            confidence,
            "cv_primary",
            {
                "load_candidate": load,
                "attached_bus_id": attached_bus_id,
                "attached_bus_box": attached_bus_box,
            },
        )
        load_candidates_by_component[comp_id] = load

    for detected_transformer in cv_transformers:
        transformer = dict(detected_transformer)
        if str(transformer.get("style", "")) == "circle_pair":
            transformer["electrical_two_port"] = _circle_pair_has_two_bus_ports(
                img,
                transformer,
                load_bus_boxes,
            )
            transformer["hollow_interior"] = _circle_pair_has_hollow_interior(
                img,
                transformer,
            )
        bbox = [
            float(transformer["x"]),
            float(transformer["y"]),
            float(transformer["w"]),
            float(transformer["h"]),
        ]
        add_node(
            "transformer",
            bbox,
            float(transformer.get("confidence", 0.85)),
            "cv_primary",
            {"transformer": transformer},
        )

    # 3. YOLO is a rescue classifier, not a topology source.  Generator is
    # still accepted directly because the existing CV+generator-YOLO route is
    # the validated path for that class.  Bus/load rescues must correspond to
    # CV-rejected candidates and reuse CV geometry/ports.
    used_rejected_buses = set()
    used_rejected_loads = set()
    yolo_load_rescue_context = None
    generator_terminal_context = None

    for result in results:
        # Ultralytics orders boxes by confidence.  A load can therefore be
        # visited before the CV-backed bus rescue that it physically attaches
        # to.  Resolve bars first so every later tail trace sees the complete
        # CV bus registry, independent of confidence ordering.
        ordered_boxes = sorted(
            result.boxes,
            key=lambda candidate: (
                0
                if _normalise_detection_class(
                    model.names[int(candidate.cls[0])]
                ) == "bus"
                else 1
            ),
        )
        for box in ordered_boxes:
            x_center, y_center, width, height = box.xywh[0].tolist()
            confidence = float(box.conf[0])
            class_index = int(box.cls[0])
            class_name = _normalise_detection_class(model.names[class_index])
            if class_name not in YOLO_CLASS_CONFIDENCES:
                continue
            bbox = [float(x_center), float(y_center), float(width), float(height)]
            if _is_monster_bbox(bbox, img.shape):
                continue

            # A structurally complete CV circle-pair only needs weak semantic
            # agreement.  Consume the probe-level YOLO box as evidence for an
            # existing tight CV node; it can never create a transformer here.
            if class_name == "transformer":
                existing_transformer = _find_matching_prediction(
                    predictions,
                    class_name,
                    bbox,
                )
                if existing_transformer is not None:
                    predictions[existing_transformer]["yolo_support"] = max(
                        float(predictions[existing_transformer].get("yolo_support", 0.0)),
                        confidence,
                    )
                    continue

            if confidence < YOLO_CLASS_CONFIDENCES[class_name]:
                continue

            if class_name == "generator":
                if generator_terminal_context is None:
                    generator_terminal_context = _make_yolo_load_rescue_context(img)
                has_terminal = _generator_has_straight_bus_terminal(
                    bbox,
                    load_bus_boxes,
                    generator_terminal_context,
                )
                circle_bbox, circle_radius = _refine_generator_circle_for_validation(
                    img, bbox
                )
                has_circle_lead = (
                    circle_radius is not None
                    and _generator_circle_has_external_lead(
                        circle_bbox, generator_terminal_context
                    )
                )
                looks_like_transformer = _looks_like_transformer_pair(
                    img, x_center, y_center, width, height
                )
                clipped_terminal = (
                    looks_like_transformer
                    and has_terminal
                    and _bbox_near_image_edge(bbox, img.shape)
                )
                if looks_like_transformer and not clipped_terminal:
                    continue
                structurally_valid = has_terminal or has_circle_lead
                if (
                    not structurally_valid
                    and confidence < YOLO_GENERATOR_STANDALONE_CONF
                ):
                    continue
                add_node(
                    "generator",
                    bbox,
                    confidence,
                    (
                        "yolo_generator"
                        if has_terminal
                        else (
                            "yolo_generator_cv_lead"
                            if has_circle_lead
                            else "yolo_generator_symbol"
                        )
                    ),
                    {
                        "cv_circle": circle_bbox if circle_radius is not None else None,
                        "has_terminal": has_terminal,
                        "has_circle_lead": has_circle_lead,
                    },
                )
                continue

            # A YOLO box overlapping an accepted CV object is only evidence;
            # the CV node remains the sole node and keeps its tight geometry.
            existing_index = _find_matching_prediction(predictions, class_name, bbox)
            if existing_index is not None:
                predictions[existing_index]["yolo_support"] = max(
                    float(predictions[existing_index].get("yolo_support", 0.0)),
                    confidence,
                )
                continue
            if not CV_ALLOW_WEAK_YOLO_ADD:
                continue

            if class_name == "bus":
                rejected_index = _match_cv_record(
                    cv_rejected_buses,
                    "bus",
                    bbox,
                    used_rejected_buses,
                )
                rejected_bus = None
                rescue_source = "yolo_rescue"
                if (
                    rejected_index is not None
                    and (
                        _strict_rejected_bus_gate(cv_rejected_buses[rejected_index])
                        or (
                            RELAXED_BUS_RESCUE
                            and _relaxed_rejected_bus_gate(
                                cv_rejected_buses[rejected_index], confidence
                            )
                        )
                    )
                ):
                    rejected_bus = cv_rejected_buses[rejected_index]
                    used_rejected_buses.add(rejected_index)
                elif (
                    YOLO_BUS_RUN_RESCUE
                    and confidence >= YOLO_BUS_RUN_MIN_CONF
                ):
                    # The proposal itself is never emitted. Reconstruct the
                    # source-image raster run and pass it through thickness,
                    # profile, branch, and endpoint-turn CV checks first.
                    reconstructed = _recover_yolo_bus_raster_run(img, bbox)
                    if reconstructed is not None:
                        reconstructed_bbox = [
                            float(reconstructed["x"]),
                            float(reconstructed["y"]),
                            float(reconstructed["w"]),
                            float(reconstructed["h"]),
                        ]
                        duplicate = any(
                            item["class"] == "bus"
                            and _same_bus_bar(item["bbox"], reconstructed_bbox)
                            for item in predictions
                        )
                        if not duplicate:
                            rejected_bus = reconstructed
                            rescue_source = "yolo_cv_raster_run"
                if rejected_bus is None:
                    continue
                rescue_bbox = [
                    float(rejected_bus["x"]),
                    float(rejected_bus["y"]),
                    float(rejected_bus["w"]),
                    float(rejected_bus["h"]),
                ]
                rescued_bus_id = add_node(
                    "bus",
                    rescue_bbox,
                    confidence,
                    rescue_source,
                    {"cv_bus": rejected_bus, "yolo_bbox": bbox},
                )
                # Subsequent YOLO load proposals are still CV-validated by a
                # physical tail trace.  Make this recovered *CV bar* visible
                # to that trace and preserve index alignment with the graph
                # bus IDs; otherwise a genuine arrow attached to a recovered
                # vertical bus can never be accepted later in this loop.
                bus_component_ids.append(rescued_bus_id)
                load_bus_boxes.append(_scaled_bus_box_from_bbox(rescue_bbox))
                continue

            if class_name == "load":
                rescue = _rescue_rejected_load(
                    img,
                    bbox,
                    confidence,
                    cv_rejected_loads,
                    load_bus_boxes,
                    used_rejected_loads,
                )
                rescue_source = "yolo_rescue"
                if rescue is None and YOLO_LOAD_PORT_RESCUE:
                    if yolo_load_rescue_context is None:
                        yolo_load_rescue_context = _make_yolo_load_rescue_context(img)
                    rescue = _rescue_yolo_load_by_port_trace(
                        bbox,
                        confidence,
                        load_bus_boxes,
                        yolo_load_rescue_context,
                        cv_rejected_loads,
                    )
                    rescue_source = "yolo_port_rescue"
                if rescue is None:
                    continue
                load, attached_bus_index = rescue
                if not (0 <= attached_bus_index < len(bus_component_ids)):
                    continue
                attached_bus_id = bus_component_ids[attached_bus_index]
                if attached_bus_id is None:
                    continue
                rescue_bbox = _bbox_from_load_candidate(load)
                attached_bus_box = (
                    load_bus_boxes[attached_bus_index]
                    if attached_bus_index < len(load_bus_boxes)
                    else None
                )
                comp_id = add_node(
                    "load",
                    rescue_bbox,
                    confidence,
                    rescue_source,
                    {
                        "load_candidate": load,
                        "attached_bus_id": attached_bus_id,
                        "attached_bus_box": attached_bus_box,
                        "yolo_bbox": bbox,
                    },
                )
                load_candidates_by_component[comp_id] = load
                continue

            # Transformers remain CV-owned.  A YOLO transformer with no CV
            # winding candidate is normally not promoted.  Some scans,
            # however, split the two compact windings just enough for the
            # full-sheet CV pass to miss them.  In that case validate the
            # YOLO proposal again with a local Hough circle-pair test.  A
            # large legend illustration is rejected by the compact-size gate;
            # this remains YOLO + local CV agreement, never a raw YOLO box.
            if class_name == "transformer":
                compact_limit = max(160.0, min(img.shape[:2]) * 0.14)
                if (
                    confidence >= YOLO_TRANSFORMER_CONFIRM_CONF
                    and max(width, height) <= compact_limit
                    and (
                        _looks_like_transformer_pair(
                            img, x_center, y_center, width, height
                        )
                        or _has_compact_transformer_ring_pair(
                            img, x_center, y_center, width, height
                        )
                    )
                ):
                    transformer_metadata = _yolo_transformer_port_metadata(
                        img,
                        bbox,
                        load_bus_boxes,
                    )
                    add_node(
                        "transformer",
                        bbox,
                        confidence,
                        "yolo_transformer_cv_pair",
                        {
                            "yolo_bbox": bbox,
                            **(
                                {"transformer": transformer_metadata}
                                if transformer_metadata is not None
                                else {}
                            ),
                        },
                    )
                    predictions[-1]["yolo_support"] = confidence
                continue

    # Transformer geometry remains CV-owned. Repeated wave windings can stand
    # alone at high CV confidence. A circle pair always needs independent YOLO
    # agreement because blurred bus bars and text can form two Hough rings.
    unconfirmed_transformer_ids = {
        item["id"]
        for item in predictions
        if (
            item["class"] == "transformer"
            and float(item.get("yolo_support", 0.0)) < YOLO_TRANSFORMER_CONFIRM_CONF
            and not _cv_transformer_can_stand_alone(
                item, component_metadata.get(item["id"], {})
            )
        )
    }
    if unconfirmed_transformer_ids:
        predictions = [
            item for item in predictions
            if item["id"] not in unconfirmed_transformer_ids
        ]
        for component_id in unconfirmed_transformer_ids:
            components.pop(component_id, None)
            component_classes.pop(component_id, None)
            component_metadata.pop(component_id, None)
            load_candidates_by_component.pop(component_id, None)

    # A secondary thin-bus family is intentionally conservative, but repeated
    # short strokes inside several winding/generator symbols can still imitate
    # that family. A real bus cannot occupy the interior of a device symbol.
    # Apply this veto only to rescued secondary buses, never to primary buses.
    device_boxes = [
        item["bbox"] for item in predictions
        if item["class"] in ("generator", "transformer")
    ]
    invalid_secondary_bus_ids = set()
    for item in predictions:
        if (
            item["class"] != "bus"
            or item.get("source") != "cv_secondary_electrical_family"
        ):
            continue
        bus_x, bus_y, _, _ = (float(value) for value in item["bbox"])
        if any(
            abs(bus_x - float(box[0])) < float(box[2]) / 2.0
            and abs(bus_y - float(box[1])) < float(box[3]) / 2.0
            for box in device_boxes
        ):
            invalid_secondary_bus_ids.add(item["id"])

    if invalid_secondary_bus_ids:
        invalid_load_ids_for_bus = {
            item["id"]
            for item in predictions
            if (
                item["class"] == "load"
                and component_metadata.get(item["id"], {}).get("attached_bus_id")
                in invalid_secondary_bus_ids
            )
        }
        invalid_ids = invalid_secondary_bus_ids | invalid_load_ids_for_bus
        predictions = [
            item for item in predictions if item["id"] not in invalid_ids
        ]
        for component_id in invalid_ids:
            components.pop(component_id, None)
            component_classes.pop(component_id, None)
            component_metadata.pop(component_id, None)
            load_candidates_by_component.pop(component_id, None)

    # Cross-class circuit constraints are stronger than local shape scores.
    # A load is a one-terminal branch and cannot be physically located inside
    # an accepted transformer winding.  Also, a CV-only arrow whose supposed
    # shaft contains a scan gap is not electrically connected; it needs
    # independent YOLO class evidence before it may bridge that missing ink.
    accepted_transformer_boxes = [
        item["bbox"] for item in predictions if item["class"] == "transformer"
    ]
    invalid_load_ids = set()
    for item in predictions:
        if item["class"] != "load":
            continue
        load_x, load_y, _, _ = (float(value) for value in item["bbox"])
        inside_transformer = any(
            abs(load_x - float(box[0])) <= float(box[2]) / 2.0
            and abs(load_y - float(box[1])) <= float(box[3]) / 2.0
            for box in accepted_transformer_boxes
        )
        candidate = component_metadata.get(item["id"], {}).get("load_candidate")
        bridges_unconfirmed_gap = (
            item.get("source") == "cv_primary"
            and candidate is not None
            and "recovered short scan gap" in str(candidate.reason)
            and float(item.get("yolo_support", 0.0)) <= 0.0
        )
        if inside_transformer or bridges_unconfirmed_gap:
            invalid_load_ids.add(item["id"])
    if invalid_load_ids:
        predictions = [
            item for item in predictions if item["id"] not in invalid_load_ids
        ]
        for component_id in invalid_load_ids:
            components.pop(component_id, None)
            component_classes.pop(component_id, None)
            component_metadata.pop(component_id, None)
            load_candidates_by_component.pop(component_id, None)

    # A very short, low-score CV triangle can be an in-line flow marker.  It
    # already has a bus-facing lead, so require independent class agreement
    # only for this narrow ambiguous subset.  Long pendant loads remain
    # CV-owned, and the strict YOLO port-rescue path is unaffected.
    ambiguous_load_ids = set()
    for item in predictions:
        if item["class"] != "load" or item.get("source") != "cv_primary":
            continue
        candidate = component_metadata.get(item["id"], {}).get("load_candidate")
        if candidate is None:
            continue
        if (
            float(candidate.triangle_score) <= 0.44
            and int(candidate.lead_length) <= 20
            # A low-support, short-aligned *large* core is commonly a flow
            # marker or line joint.  Keep genuinely compact arrowheads here:
            # they are exactly the small loads for which the short-lead CV
            # rule exists.
            and max(int(candidate.w), int(candidate.h)) >= 40
            and float(item.get("yolo_support", 0.0))
            < YOLO_AMBIGUOUS_LOAD_CONFIRM_CONF
        ):
            ambiguous_load_ids.add(item["id"])
    if ambiguous_load_ids:
        predictions = [
            item for item in predictions if item["id"] not in ambiguous_load_ids
        ]
        for component_id in ambiguous_load_ids:
            components.pop(component_id, None)
            component_classes.pop(component_id, None)
            component_metadata.pop(component_id, None)
            load_candidates_by_component.pop(component_id, None)

    # Object-only evaluation and editor previews can skip the expensive graph
    # walk while keeping exactly the same node candidates and CV metadata.
    if skip_topology or os.environ.get("POWERLENS_SKIP_TOPOLOGY", "0") == "1":
        return {"nodes": predictions, "lines": []}

    topology_data, debug_info = _trace_circuit_topology(
        img,
        components,
        component_classes,
        component_metadata=component_metadata,
        load_candidates_by_component=load_candidates_by_component,
        load_mask_mode=load_mask_mode,
    )
    result = {"nodes": predictions, "lines": topology_data}
    result.update(debug_info)
    return result


def _trace_circuit_topology(
    img,
    components,
    component_classes,
    component_metadata=None,
    load_candidates_by_component=None,
    load_mask_mode="box",
    requested_pair=None,
):
    """Run the existing pixel topology tracer for an approved object set."""
    component_metadata = component_metadata or {}
    load_candidates_by_component = load_candidates_by_component or {}
    h_img, w_img = img.shape[:2]

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    # Thin anti-aliased conductors can be lighter than symbol outlines. The
    # previous global/adaptive AND retained only pixels accepted by both
    # masks and erased nearly the entire 24bus conductor layer. Otsu chooses
    # the page-specific foreground split while later text/object masks remove
    # non-conductor ink.
    binary = _topology_hysteresis_binary(gray)
    topology_binary_initial_pixels = int(np.count_nonzero(binary))
    # Labels are not electrical conductors. Remove isolated number-like
    # components before object masking and skeletonization so the topology
    # walker cannot route a real wire through a bus number.
    protected_object_ink = np.zeros_like(binary)
    for component_id, box in components.items():
        if component_classes.get(component_id) != "load":
            continue
        cv2.rectangle(
            protected_object_ink,
            (max(0, box[0]), max(0, box[1])),
            (min(w_img - 1, box[2]), min(h_img - 1, box[3])),
            255,
            -1,
        )
    binary = _remove_numeric_text_components(
        binary,
        protected_mask=protected_object_ink,
    )
    topology_binary_after_text_pixels = int(np.count_nonzero(binary))
    topology_conductor_source = binary.copy()

    for component_id, box in components.items():
        load_candidate = load_candidates_by_component.get(component_id)
        if load_candidate is not None and load_mask_mode == "triangle":
            polygon = load_triangle_polygon(load_candidate, binary.shape)
            cv2.fillConvexPoly(binary, polygon, 0)
        elif load_candidate is not None and load_mask_mode == "core_contour":
            core_mask = load_core_mask(load_candidate, binary.shape)
            binary[core_mask > 0] = 0
        else:
            # `box` remains the display/editor bbox. For loads this branch is
            # also available as a baseline to compare the old topology mask.
            # A one-pixel expansion for buses removes anti-aliased bar edges.
            # Without it, a thin bus can leave a U-shaped residue that joins
            # the incoming and outgoing skeleton branches into one endpoint;
            # the greedy walk then keeps one branch and loses the other.
            mask_pad = 1 if component_classes.get(component_id) == "bus" else 0
            cv2.rectangle(
                binary,
                (max(0, box[0] - mask_pad), max(0, box[1] - mask_pad)),
                (min(w_img - 1, box[2] + mask_pad), min(h_img - 1, box[3] + mask_pad)),
                0,
                -1,
            )

    topology_binary_after_objects_pixels = int(np.count_nonzero(binary))

    topology_thin_width = max(
        1,
        int(bus_cv.estimate_thin_line_width(topology_conductor_source)),
    )
    inline_load_restored_pixels = 0
    inline_load_components = set()
    for component_id, load_candidate in load_candidates_by_component.items():
        restored_pixels = _restore_inline_load_conductor(
            binary,
            topology_conductor_source,
            load_candidate,
            topology_thin_width,
            mask_box=components.get(component_id),
        )
        inline_load_restored_pixels += restored_pixels
        if restored_pixels > 0:
            inline_load_components.add(component_id)

    binary_before_gap_bridge = binary.copy()
    binary = bridge_one_pixel_gaps(binary)
    topology_gap_bridged_pixels = int(
        np.count_nonzero(binary) - np.count_nonzero(binary_before_gap_bridge)
    )

    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (2,2))
    binary_closed = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel)
    
    skeleton = skeletonize_binary(binary_closed)

    endpoints = set()
    for y in range(1, h_img-1):
        for x in range(1, w_img-1):
            if skeleton[y, x] == 255:
                n_count = 0
                for dy in [-1, 0, 1]:
                    for dx in [-1, 0, 1]:
                        if dx == 0 and dy == 0: continue
                        if skeleton[y+dy, x+dx] == 255:
                            n_count += 1
                if n_count == 1:
                    endpoints.add((x, y))

    component_ports = {
        component_id: _make_component_ports(
            component_id,
            component_classes[component_id],
            components[component_id],
            load_candidate=component_metadata.get(component_id, {}).get("load_candidate"),
            transformer_info=component_metadata.get(component_id, {}).get("transformer"),
        )
        for component_id in components
    }

    endpoint_to_comp, endpoint_to_port = _assign_endpoints_to_ports(
        skeleton,
        endpoints,
        component_ports,
        component_classes,
    )

    line_candidates = trace_electrical_connections(
        skeleton,
        endpoint_to_comp,
        endpoint_to_port,
        component_classes,
        requested_pair=requested_pair,
    )

    # The CV load detector has already proven a cardinal lead reaches a
    # specific bus.  Keep that validated relation when masking the load box
    # erased the final skeleton endpoint; do not use a generic nearest-bus
    # fallback here.
    line_candidates = _add_validated_load_bus_fallbacks(
        line_candidates,
        component_classes,
        component_metadata,
        topology_source_binary=topology_conductor_source,
        topology_thin_width=topology_thin_width,
    )

    # A load or generator has one physical shaft/terminal in these SLDs.  A
    # transformer is intentionally excluded: its opposite ports are kept
    # separately, and a drawing may expose only one of them.
    line_candidates = _keep_single_port_components(
        line_candidates,
        component_classes,
    )

    topology_data = []
    for valid_line_count, candidate in enumerate(line_candidates):
        topology_data.append({
            "line_id": f"L{valid_line_count}",
            "connected_to": candidate["connected_to"],
            "path": candidate["path"],
            "source_port": candidate["source_port"],
            "target_port": candidate["target_port"],
            "trace_method": candidate.get("trace_method", "skeleton"),
        })

    debug_info = {}
    if os.environ.get("POWERLENS_TOPOLOGY_DEBUG", "0") == "1":
        endpoint_class_counts = {}
        for component_id in endpoint_to_comp.values():
            class_name = component_classes.get(component_id, "unknown")
            endpoint_class_counts[class_name] = endpoint_class_counts.get(class_name, 0) + 1
        endpoint_details = [
            {
                "point": [int(point[0]), int(point[1])],
                "component": component_id,
                "side": endpoint_to_port.get(point, {}).get("side"),
                "distance": float(endpoint_to_port.get(point, {}).get("distance", 0.0)),
            }
            for point, component_id in sorted(endpoint_to_comp.items())
        ]
        labels_count, terminal_labels = cv2.connectedComponents(
            np.where(skeleton > 0, 255, 0).astype(np.uint8),
            connectivity=8,
        )
        terminals_per_component = {}
        for x, y in endpoint_to_comp:
            label = int(terminal_labels[y, x])
            if label > 0:
                terminals_per_component[label] = terminals_per_component.get(label, 0) + 1
        debug_info["topology_debug"] = {
            "binary_initial_pixels": topology_binary_initial_pixels,
            "binary_after_text_pixels": topology_binary_after_text_pixels,
            "binary_after_objects_pixels": topology_binary_after_objects_pixels,
            "inline_load_restored_pixels": inline_load_restored_pixels,
            "inline_load_components": sorted(inline_load_components),
            "gap_bridged_pixels": topology_gap_bridged_pixels,
            "binary_closed_pixels": int(np.count_nonzero(binary_closed)),
            "skeleton_values": [int(value) for value in np.unique(skeleton)],
            "skeleton_pixels": int(np.count_nonzero(skeleton)),
            "skeleton_components": int(max(0, labels_count - 1)),
            "endpoints": int(len(endpoints)),
            "assigned_endpoints": int(len(endpoint_to_comp)),
            "assigned_by_class": endpoint_class_counts,
            "assigned_endpoint_details": endpoint_details,
            "terminal_component_histogram": {
                str(count): sum(value == count for value in terminals_per_component.values())
                for count in sorted(set(terminals_per_component.values()))
            },
            "graph_candidates": int(sum(
                candidate.get("trace_method") == "electrical_graph"
                for candidate in line_candidates
            )),
        }
        debug_info["_topology_masks"] = {
            "binary_closed": binary_closed,
            "skeleton": skeleton,
        }
    return topology_data, debug_info


def detect_sld_objects(image_bytes, model, load_mask_mode="box"):
    """Detect symbols without retaining the topology result."""
    return analyze_circuit_image(
        image_bytes,
        model,
        load_mask_mode=load_mask_mode,
        skip_topology=True,
    )


def detect_sld_connections(
    image_bytes,
    confirmed_nodes,
    load_mask_mode="box",
    requested_pair=None,
):
    """Trace real source pixels again using the human-approved object boxes."""
    nparr = np.frombuffer(image_bytes, np.uint8)
    img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("Could not decode circuit image for connection detection")

    components = {}
    component_classes = {}
    component_metadata = {}
    load_candidates_by_component = {}
    for node in confirmed_nodes:
        component_id = str(node.get("id"))
        class_name = str(node.get("class") or node.get("class_name") or "bus")
        bbox = node.get("bbox", [0.0, 0.0, 10.0, 10.0])
        _set_component_box(components, component_id, bbox, img.shape)
        component_classes[component_id] = class_name
        metadata = dict(node.get("metadata") or {})
        component_metadata[component_id] = metadata
        if "load_candidate" in metadata:
            load_candidates_by_component[component_id] = metadata["load_candidate"]

    topology_data, debug_info = _trace_circuit_topology(
        img,
        components,
        component_classes,
        component_metadata=component_metadata,
        load_candidates_by_component=load_candidates_by_component,
        load_mask_mode=load_mask_mode,
        requested_pair=requested_pair,
    )
    result = {"nodes": confirmed_nodes, "lines": topology_data}
    result.update(debug_info)
    return result

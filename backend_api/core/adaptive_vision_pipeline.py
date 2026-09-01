"""Production-safe adaptive wrapper around the proven vision detector.

Normal 1280px regression images follow the existing code path byte-for-byte.
Only clearly low/high-resolution inputs are resized to a stable working scale;
all returned boxes and topology paths are mapped back to original coordinates.
The wrapper also attaches a machine-readable policy/graph report for the
Flutter review step and later power-flow validation.
"""

from __future__ import annotations

import copy
import os
from typing import Any

import cv2
import numpy as np

try:
    from .pipeline_policy import build_runtime_report, inspect_image
    from .vision_logic import (
        analyze_circuit_image,
        detect_sld_objects,
        detect_sld_connections,
    )
except ImportError:  # Direct backend_api execution.
    from core.pipeline_policy import build_runtime_report, inspect_image
    from core.vision_logic import (
        analyze_circuit_image,
        detect_sld_objects,
        detect_sld_connections,
    )


ADAPTIVE_RESIZE_ENABLED = os.environ.get(
    "POWERLENS_ADAPTIVE_RESIZE", "1"
) == "1"


def _encode_image(image: np.ndarray) -> bytes:
    ok, encoded = cv2.imencode(".png", image)
    if not ok:
        raise ValueError("Could not encode normalized circuit image")
    return encoded.tobytes()


def _resize_for_scale(image: np.ndarray, scale: float) -> np.ndarray:
    if abs(scale - 1.0) < 0.01:
        return image
    height, width = image.shape[:2]
    target = (
        max(1, int(round(width * scale))),
        max(1, int(round(height * scale))),
    )
    interpolation = cv2.INTER_LANCZOS4 if scale > 1.0 else cv2.INTER_AREA
    return cv2.resize(image, target, interpolation=interpolation)


def _rescale_result(result: dict[str, Any], processing_scale: float) -> dict[str, Any]:
    if abs(processing_scale - 1.0) < 0.01:
        return result
    output = copy.deepcopy(result)
    inverse = 1.0 / processing_scale
    for node in output.get("nodes", []):
        bbox = node.get("bbox")
        if isinstance(bbox, (list, tuple)) and len(bbox) == 4:
            node["bbox"] = [float(value) * inverse for value in bbox]
    for line in output.get("lines", []):
        path = line.get("path")
        if isinstance(path, list):
            line["path"] = [
                [int(round(point[0] * inverse)), int(round(point[1] * inverse))]
                for point in path
                if isinstance(point, (list, tuple)) and len(point) == 2
            ]
        distances = line.get("port_distances")
        if isinstance(distances, dict):
            line["port_distances"] = {
                key: float(value) * inverse
                for key, value in distances.items()
            }
    return output


def analyze_circuit_image_adaptive(
    image_bytes: bytes,
    model: Any,
    load_mask_mode: str = "box",
) -> dict[str, Any]:
    buffer = np.frombuffer(image_bytes, np.uint8)
    original = cv2.imdecode(buffer, cv2.IMREAD_COLOR)
    if original is None:
        raise ValueError("Could not decode circuit image")

    profile = inspect_image(original)
    processing_scale = (
        profile.recommended_scale if ADAPTIVE_RESIZE_ENABLED else 1.0
    )
    # Avoid a needless image re-encode for the normal regression family.
    if abs(processing_scale - 1.0) < 0.01:
        result = analyze_circuit_image(
            image_bytes,
            model,
            load_mask_mode=load_mask_mode,
        )
        processing_scale = 1.0
    else:
        working = _resize_for_scale(original, processing_scale)
        result = analyze_circuit_image(
            _encode_image(working),
            model,
            load_mask_mode=load_mask_mode,
        )
        result = _rescale_result(result, processing_scale)

    result["pipeline"] = build_runtime_report(
        profile,
        result.get("nodes", []),
        result.get("lines", []),
        processing_scale,
    )
    return result


def detect_sld_objects_adaptive(
    image_bytes: bytes,
    model: Any,
    load_mask_mode: str = "box",
) -> dict[str, Any]:
    """Detect SLD symbols using the adaptive-scale pipeline without connection tracing."""
    buffer = np.frombuffer(image_bytes, np.uint8)
    original = cv2.imdecode(buffer, cv2.IMREAD_COLOR)
    if original is None:
        raise ValueError("Could not decode circuit image for object detection")

    profile = inspect_image(original)
    processing_scale = (
        profile.recommended_scale if ADAPTIVE_RESIZE_ENABLED else 1.0
    )
    if abs(processing_scale - 1.0) < 0.01:
        result = detect_sld_objects(
            image_bytes,
            model,
            load_mask_mode=load_mask_mode,
        )
        processing_scale = 1.0
    else:
        working = _resize_for_scale(original, processing_scale)
        result = detect_sld_objects(
            _encode_image(working),
            model,
            load_mask_mode=load_mask_mode,
        )
        result = _rescale_result(result, processing_scale)

    result["pipeline"] = build_runtime_report(
        profile,
        result.get("nodes", []),
        [],
        processing_scale,
    )
    return result


def detect_sld_connections_adaptive(
    image_bytes: bytes,
    confirmed_nodes: list[dict[str, Any]],
    load_mask_mode: str = "box",
) -> dict[str, Any]:
    """Trace SLD connections from externally confirmed nodes with adaptive scaling."""
    buffer = np.frombuffer(image_bytes, np.uint8)
    original = cv2.imdecode(buffer, cv2.IMREAD_COLOR)
    if original is None:
        raise ValueError("Could not decode circuit image for connection detection")

    profile = inspect_image(original)
    processing_scale = (
        profile.recommended_scale if ADAPTIVE_RESIZE_ENABLED else 1.0
    )
    if abs(processing_scale - 1.0) < 0.01:
        result = detect_sld_connections(
            image_bytes,
            confirmed_nodes,
            load_mask_mode=load_mask_mode,
        )
        processing_scale = 1.0
    else:
        working = _resize_for_scale(original, processing_scale)
        scaled_nodes = copy.deepcopy(confirmed_nodes)
        for node in scaled_nodes:
            bbox = node.get("bbox")
            if isinstance(bbox, (list, tuple)) and len(bbox) == 4:
                node["bbox"] = [float(val) * processing_scale for val in bbox]
        raw_result = detect_sld_connections(
            _encode_image(working),
            scaled_nodes,
            load_mask_mode=load_mask_mode,
        )
        rescaled_result = _rescale_result(raw_result, processing_scale)
        result = {
            "nodes": confirmed_nodes,
            "lines": rescaled_result.get("lines", []),
        }

    result["pipeline"] = build_runtime_report(
        profile,
        result.get("nodes", confirmed_nodes),
        result.get("lines", []),
        processing_scale,
    )
    return result


__all__ = [
    "analyze_circuit_image_adaptive",
    "detect_sld_objects_adaptive",
    "detect_sld_connections_adaptive",
    "_rescale_result",
]


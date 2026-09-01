"""ROI Re-analysis Adapter Tools for VisionFlow Agent Object Reviewer."""
from __future__ import annotations

from typing import Any, Dict, List
import cv2
import numpy as np


def _crop_roi(image: np.ndarray, bbox: List[float], pad_ratio: float = 0.2) -> tuple[np.ndarray, tuple[int, int, int, int]]:
    """Crop a bounding box from image with padding."""
    h_img, w_img = image.shape[:2]
    cx, cy, w, h = bbox
    pad_w = w * pad_ratio
    pad_h = h * pad_ratio

    x1 = max(0, int(cx - w / 2.0 - pad_w))
    y1 = max(0, int(cy - h / 2.0 - pad_h))
    x2 = min(w_img, int(cx + w / 2.0 + pad_w))
    y2 = min(h_img, int(cy + h / 2.0 + pad_h))

    roi = image[y1:y2, x1:x2]
    return roi, (x1, y1, x2, y2)


def reanalyze_generator_roi(image: np.ndarray, bbox: List[float]) -> Dict[str, Any]:
    """Re-analyze a candidate generator ROI for circular symbol structure."""
    roi, _ = _crop_roi(image, bbox)
    if roi.size == 0:
        return {"has_circle": False, "confidence": 0.0, "reason": "Empty ROI"}

    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    # Hough circle detection on the localized ROI
    min_r = max(4, int(min(bbox[2], bbox[3]) * 0.25))
    max_r = int(max(bbox[2], bbox[3]) * 0.6)

    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,
        dp=1.2,
        minDist=min_r * 2,
        param1=50,
        param2=30,
        minRadius=min_r,
        maxRadius=max_r,
    )

    if circles is not None and len(circles) > 0:
        return {
            "has_circle": True,
            "detected_circles_count": len(circles[0]),
            "score": 0.85,
            "evidence": "Found clear circular pattern in ROI",
        }
    return {
        "has_circle": False,
        "score": 0.35,
        "evidence": "No clear single circular boundary detected in ROI",
    }


def reanalyze_transformer_roi(image: np.ndarray, bbox: List[float]) -> Dict[str, Any]:
    """Re-analyze a candidate transformer ROI for dual-winding/circle pair structure."""
    roi, _ = _crop_roi(image, bbox, pad_ratio=0.1)
    if roi.size == 0:
        return {"is_pair": False, "score": 0.0, "reason": "Empty ROI"}

    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (3, 3), 0)
    min_r = max(3, int(min(bbox[2], bbox[3]) * 0.15))
    max_r = int(max(bbox[2], bbox[3]) * 0.45)

    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,
        dp=1.0,
        minDist=min_r,
        param1=40,
        param2=20,
        minRadius=min_r,
        maxRadius=max_r,
    )

    if circles is not None and len(circles[0]) >= 2:
        return {
            "is_pair": True,
            "winding_count": int(len(circles[0])),
            "score": 0.88,
            "evidence": f"Found {len(circles[0])} circle winding elements",
        }
    return {
        "is_pair": False,
        "score": 0.40,
        "evidence": "Could not confirm distinct dual-circle or wavy transformer symbol",
    }


def reanalyze_bus_roi(image: np.ndarray, bbox: List[float]) -> Dict[str, Any]:
    """Re-analyze a candidate bus ROI for straight bar morphology."""
    roi, _ = _crop_roi(image, bbox, pad_ratio=0.1)
    if roi.size == 0:
        return {"is_straight_bar": False, "score": 0.0, "reason": "Empty ROI"}

    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)

    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return {"is_straight_bar": False, "score": 0.20, "evidence": "No ink contour in ROI"}

    largest = max(contours, key=cv2.contourArea)
    rect = cv2.minAreaRect(largest)
    w_box, h_box = rect[1]
    aspect = max(w_box, h_box) / max(min(w_box, h_box), 1e-4)

    is_bar = aspect >= 2.5 and cv2.contourArea(largest) > 20
    return {
        "is_straight_bar": bool(is_bar),
        "aspect_ratio": float(aspect),
        "score": 0.90 if is_bar else 0.45,
        "evidence": f"Contour aspect ratio is {aspect:.1f} ({'Straight bar verified' if is_bar else 'Too short/square'})",
    }


def reanalyze_load_roi(image: np.ndarray, bbox: List[float]) -> Dict[str, Any]:
    """Re-analyze a candidate load ROI for triangular/arrowhead shape."""
    roi, _ = _crop_roi(image, bbox, pad_ratio=0.15)
    if roi.size == 0:
        return {"is_arrowhead": False, "score": 0.0, "reason": "Empty ROI"}

    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)

    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return {"is_arrowhead": False, "score": 0.20, "evidence": "No ink contour in ROI"}

    largest = max(contours, key=cv2.contourArea)
    hull = cv2.convexHull(largest)
    solidity = cv2.contourArea(largest) / max(cv2.contourArea(hull), 1e-4)

    # Approximate polygon
    epsilon = 0.04 * cv2.arcLength(largest, True)
    approx = cv2.approxPolyDP(largest, epsilon, True)

    is_triangle = len(approx) in (3, 4) and solidity > 0.70
    return {
        "is_arrowhead": bool(is_triangle),
        "vertex_count": int(len(approx)),
        "solidity": float(solidity),
        "score": 0.85 if is_triangle else 0.40,
        "evidence": f"Polygon approximation has {len(approx)} vertices with solidity {solidity:.2f}",
    }

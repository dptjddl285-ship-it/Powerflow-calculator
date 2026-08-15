"""YOLO plus image-only arrow fallback for power-diagram loads."""

import io
import os

import cv2
import numpy as np
from PIL import Image
from ultralytics import YOLO


CLASS_MAP = {0: "bus", 1: "generator", 2: "load", 3: "transformer"}
MODEL_PATH = os.environ.get("AUTO_TUNE_MODEL_PATH", "backend_api/icon_recognition/models/best.pt")
CONFIDENCE = float(os.environ.get("AUTO_TUNE_CONFIDENCE", "0.25"))
MODEL = YOLO(MODEL_PATH)


def iou(a, b):
    ax1, ay1 = a[0] - a[2] / 2, a[1] - a[3] / 2
    ax2, ay2 = a[0] + a[2] / 2, a[1] + a[3] / 2
    bx1, by1 = b[0] - b[2] / 2, b[1] - b[3] / 2
    bx2, by2 = b[0] + b[2] / 2, b[1] + b[3] / 2
    intersection = max(0, min(ax2, bx2) - max(ax1, bx1)) * max(0, min(ay2, by2) - max(ay1, by1))
    return intersection / (a[2] * a[3] + b[2] * b[3] - intersection + 1e-6)


def load_arrow_candidates(image):
    gray = cv2.cvtColor(image, cv2.COLOR_RGB2GRAY)
    _, ink = cv2.threshold(gray, 140, 255, cv2.THRESH_BINARY_INV)
    opened = cv2.morphologyEx(ink, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3)))
    contours, _ = cv2.findContours(opened, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    candidates = []
    for contour in contours:
        area = cv2.contourArea(contour)
        x, y, width, height = cv2.boundingRect(contour)
        vertices = len(cv2.approxPolyDP(contour, 0.08 * cv2.arcLength(contour, True), True))
        if vertices != 3 or not 100 <= area <= 500 or not (10 <= width <= 40 and 10 <= height <= 40):
            continue
        candidates.append({"class": "load", "bbox": [x + width / 2, y + height / 2, width * 1.25, height * 1.25],
                           "confidence": 1.0, "source": "opencv_arrow"})
    return candidates


def analyze_circuit_image_hybrid_autotune(image_bytes):
    image = np.array(Image.open(io.BytesIO(image_bytes)).convert("RGB"))
    # Keep low-confidence proposals only as corroboration for image-derived arrows.
    result = MODEL.predict(image, conf=0.001, iou=0.4, max_det=300, verbose=False)[0]
    nodes = []
    low_confidence_loads = []
    for box in result.boxes:
        x1, y1, x2, y2 = box.xyxy[0].tolist()
        node = {"class": CLASS_MAP[int(box.cls[0])], "bbox": [(x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1],
                "confidence": float(box.conf[0]), "source": "yolo"}
        if node["class"] == "load":
            low_confidence_loads.append(node)
        if node["confidence"] >= CONFIDENCE:
            nodes.append(node)
    for candidate in load_arrow_candidates(image):
        corroborated = any(iou(node["bbox"], candidate["bbox"]) >= 0.1 for node in low_confidence_loads)
        if corroborated and not any(node["class"] == "load" and iou(node["bbox"], candidate["bbox"]) >= 0.4 for node in nodes):
            nodes.append(candidate)
    return {"status": "success", "nodes": nodes}

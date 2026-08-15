"""Topology-filtered YOLO plus conservative image-only Load recovery."""

import io

import cv2
import numpy as np
from PIL import Image

from backend_api.line_recognition.logic.topology_load_recovery import recover_missing_loads
from backend_api.line_recognition.logic.vision_logic_topology_hybrid import analyze_circuit_image_topology_hybrid


def _iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    intersection = max(0, min(ax2, bx2) - max(ax1, bx1)) * max(0, min(ay2, by2) - max(ay1, by1))
    union = (ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - intersection
    return intersection / union if union else 0.0


def analyze_circuit_image_recovery_hybrid(image_bytes):
    result = analyze_circuit_image_topology_hybrid(image_bytes)
    nodes = result["nodes"]
    image = np.array(Image.open(io.BytesIO(image_bytes)).convert("RGB"))
    bgr = cv2.cvtColor(image, cv2.COLOR_RGB2BGR)
    existing = []
    for index, node in enumerate(nodes):
        x, y, w, h = node["bbox"]
        existing.append({"id": f"node_{index}", "bbox": [x - w / 2, y - h / 2, x + w / 2, y + h / 2]})
    for recovered in recover_missing_loads(bgr, existing):
        x1, y1, x2, y2 = recovered["bbox"]
        if any(node["class"] == "load" and _iou(recovered["bbox"], box["bbox"]) >= .2 for node, box in zip(nodes, existing)):
            continue
        nodes.append({"class": "load", "bbox": [(x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1], "confidence": .05, "source": "opencv_topology_recovery"})
    return {"status": "success", "nodes": nodes}

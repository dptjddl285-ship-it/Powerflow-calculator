"""Image-only overlapping-tile YOLO inference for small circuit symbols."""

import io
import os

import numpy as np
from PIL import Image
from ultralytics import YOLO


CLASS_MAP = {0: "bus", 1: "generator", 2: "load", 3: "transformer"}
MODEL_PATH = os.environ.get("AUTO_TUNE_MODEL_PATH", "backend_api/icon_recognition/models/best.pt")
CONFIDENCE = float(os.environ.get("AUTO_TUNE_CONFIDENCE", "0.25"))
CLASS_CONFIDENCES = {
    key.strip(): float(value)
    for key, value in (item.split("=", 1) for item in os.environ.get("AUTO_TUNE_CLASS_CONFIDENCES", "").split(",") if "=" in item)
}
TILE_NMS_IOU = float(os.environ.get("AUTO_TUNE_TILE_NMS_IOU", "0.4"))
MODEL = YOLO(MODEL_PATH)


def _iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    intersection = max(0, min(ax2, bx2) - max(ax1, bx1)) * max(0, min(ay2, by2) - max(ay1, by1))
    union = (ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - intersection
    return intersection / union if union else 0.0


def analyze_circuit_image_tiled_autotune(image_bytes):
    image = np.array(Image.open(io.BytesIO(image_bytes)).convert("RGB"))
    height, width = image.shape[:2]
    tile_width, tile_height = int(width * .6), int(height * .6)
    origins_x = (0, width - tile_width)
    origins_y = (0, height - tile_height)
    candidates = []
    inference_confidence = min([CONFIDENCE, *CLASS_CONFIDENCES.values()])
    for origin_y in origins_y:
        for origin_x in origins_x:
            tile = image[origin_y:origin_y + tile_height, origin_x:origin_x + tile_width]
            result = MODEL.predict(tile, conf=inference_confidence, iou=.4, max_det=300, verbose=False)[0]
            for box in result.boxes:
                class_name = CLASS_MAP[int(box.cls[0])]
                confidence = float(box.conf[0])
                if confidence < CLASS_CONFIDENCES.get(class_name, CONFIDENCE):
                    continue
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                candidates.append({"class": class_name, "xyxy": [x1 + origin_x, y1 + origin_y, x2 + origin_x, y2 + origin_y], "confidence": confidence})
    selected = []
    for candidate in sorted(candidates, key=lambda item: item["confidence"], reverse=True):
        if not any(candidate["class"] == kept["class"] and _iou(candidate["xyxy"], kept["xyxy"]) >= TILE_NMS_IOU for kept in selected):
            selected.append(candidate)
    nodes = []
    for item in selected:
        x1, y1, x2, y2 = item["xyxy"]
        nodes.append({"class": item["class"], "bbox": [(x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1], "confidence": item["confidence"], "source": "tiled_yolo"})
    return {"status": "success", "nodes": nodes}

"""Generic model-only candidate used by the auto-tune evaluator.

The model path and confidence threshold are process settings.  No labels,
filenames, or sample-specific coordinates are consulted during inference.
"""

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
MODEL = YOLO(MODEL_PATH)


def analyze_circuit_image_autotune(image_bytes):
    image = np.array(Image.open(io.BytesIO(image_bytes)).convert("RGB"))
    # Infer broadly, then apply optional class-specific confidence gates.  This
    # lets each symbol class use its own calibrated threshold without any
    # image-name or label-dependent rule.
    result = MODEL.predict(image, conf=min([CONFIDENCE, *CLASS_CONFIDENCES.values()]), iou=0.4, max_det=300, verbose=False)[0]
    nodes = []
    for box in result.boxes:
        x1, y1, x2, y2 = box.xyxy[0].tolist()
        class_name = CLASS_MAP[int(box.cls[0])]
        confidence = float(box.conf[0])
        if confidence < CLASS_CONFIDENCES.get(class_name, CONFIDENCE):
            continue
        nodes.append({
            "class": class_name,
            "bbox": [(x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1],
            "confidence": confidence,
            "source": "yolo",
        })
    return {"status": "success", "nodes": nodes}

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


CLASS_MAP = {0: "bus", 1: "generator", 2: "load", 3: "transformer"}
MODEL_PATH = os.environ.get("AUTO_TUNE_MODEL_PATH", "backend_api/icon_recognition/models/best.pt")
CONFIDENCE = float(os.environ.get("AUTO_TUNE_CONFIDENCE", "0.25"))
DEFAULT_CLASS_CONFIDENCES = {
    "bus": 0.30,
    "generator": 0.50,
    "load": 0.27,
    "transformer": 0.50,
}
CLASS_CONFIDENCES = {
    key.strip(): float(value)
    for key, value in (item.split("=", 1) for item in os.environ.get("AUTO_TUNE_CLASS_CONFIDENCES", "").split(",") if "=" in item)
}
CLASS_CONFIDENCES = {**DEFAULT_CLASS_CONFIDENCES, **CLASS_CONFIDENCES}
DROP_ISOLATED_LOADS = os.environ.get("AUTO_TUNE_DROP_ISOLATED_LOADS", "1") == "1"
LOAD_BBOX_SCALE = float(os.environ.get("AUTO_TUNE_LOAD_BBOX_SCALE", "1.04"))
TOPOLOGY_DILATION_ITERATIONS = int(os.environ.get("AUTO_TUNE_TOPOLOGY_DILATION_ITERATIONS", "12"))
MODEL = YOLO(MODEL_PATH)


def suppress_overlapping_bus_fragments(nodes):
    """Remove lower-confidence fragments of the same collinear Bus.

    Diagram rasterization can split one physical horizontal Bus into two
    overlapping detections.  This uses only predicted box geometry, retaining
    the higher-confidence proposal and leaving separate or merely parallel
    buses untouched.
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
                duplicate = True
                break
        if not duplicate:
            retained.append(node)
    return retained


def analyze_circuit_image_topology_hybrid(image_bytes):
    rgb = np.array(Image.open(io.BytesIO(image_bytes)).convert("RGB"))
    result = MODEL.predict(rgb, conf=min([CONFIDENCE, *CLASS_CONFIDENCES.values()]), iou=0.4, max_det=300, verbose=False)[0]
    nodes, topology_boxes = [], []
    for index, box in enumerate(result.boxes):
        class_name = CLASS_MAP[int(box.cls[0])]
        confidence = float(box.conf[0])
        if confidence < CLASS_CONFIDENCES.get(class_name, CONFIDENCE):
            continue
        x1, y1, x2, y2 = box.xyxy[0].tolist()
        width, height = x2 - x1, y2 - y1
        if class_name == "load":
            width *= LOAD_BBOX_SCALE
            height *= LOAD_BBOX_SCALE
        node = {
            "class": class_name,
            "bbox": [(x1 + x2) / 2, (y1 + y2) / 2, width, height],
            "confidence": confidence,
            "source": "yolo+topology",
            "_topology_id": f"{class_name}_{index}",
        }
        nodes.append(node)
        topology_boxes.append({"id": node["_topology_id"], "bbox": [x1, y1, x2, y2]})

    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    connections, topology_debug = extract_line_topology(
        bgr, topology_boxes, dilation_iters=TOPOLOGY_DILATION_ITERATIONS
    )
    linked_ids = {node_id for pair in connections for node_id in pair}
    wire_contact_ids = {
        node_id for node_id, line_ids in (topology_debug or {}).get("box_to_lines", {}).items()
        if line_ids
    }
    if DROP_ISOLATED_LOADS:
        nodes = [
            node for node in nodes
            if node["class"] != "load"
            or node["_topology_id"] in linked_ids
            or node["_topology_id"] in wire_contact_ids
        ]
    nodes = suppress_overlapping_bus_fragments(nodes)
    for node in nodes:
        node.pop("_topology_id", None)
    return {"status": "success", "nodes": nodes}

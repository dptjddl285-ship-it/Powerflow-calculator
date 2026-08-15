import sys, os
sys.path.insert(0, os.path.abspath('.'))
import cv2, numpy as np
from pathlib import Path
from backend_api.validation_tests.auto_tune_evaluator import labels_for, iou
from backend_api.line_recognition.logic.vision_logic_topology_hybrid import (
    MODEL, CLASS_MAP, _letterbox_to_reference, _looks_like_numeric_text,
    _has_direct_wire_contact, has_distinct_load_bypass_shape,
    has_blue_load_pixels
)

# Test duplicate transformer suppression
def suppress_overlapping_transformers(boxes):
    keep = []
    sorted_b = sorted(boxes, key=lambda x: x[1], reverse=True)
    for b in sorted_b:
        (x1, y1, x2, y2), conf = b[0], b[1]
        area = (x2 - x1) * (y2 - y1)
        suppressed = False
        for k in keep:
            (kx1, ky1, kx2, ky2), kconf = k[0], k[1]
            karea = (kx2 - kx1) * (ky2 - ky1)
            ix1, iy1 = max(x1, kx1), max(y1, ky1)
            ix2, iy2 = min(x2, kx2), min(y2, ky2)
            if ix2 > ix1 and iy2 > iy1:
                inter = (ix2 - ix1) * (iy2 - iy1)
                ioa = inter / min(area, karea)
                iou_val = inter / (area + karea - inter)
                if ioa > 0.35 or iou_val > 0.20:
                    suppressed = True
                    break
        if not suppressed:
            keep.append(b)
    return keep

print("Testing Transformer suppression on Image 08...")
img8 = cv2.imread('new pictures/KakaoTalk_20260815_154947878_08.jpg')
ref8, s8, ox8, oy8 = _letterbox_to_reference(img8)
res8 = MODEL.predict(ref8, conf=0.05, verbose=False)[0]
trans_boxes = []
for b in res8.boxes:
    if CLASS_MAP[int(b.cls[0])] == 'transformer':
        rx1, ry1, rx2, ry2 = b.xyxy[0].tolist()
        ox1, oy1, ox2, oy2 = int((rx1-ox8)/s8), int((ry1-oy8)/s8), int((rx2-ox8)/s8), int((ry2-oy8)/s8)
        trans_boxes.append(((ox1, oy1, ox2, oy2), float(b.conf[0])))

print(f"Raw transformers in image 08: {len(trans_boxes)}")
for tb in trans_boxes:
    print("  ", tb)

kept = suppress_overlapping_transformers(trans_boxes)
print(f"Suppressed transformers in image 08: {len(kept)}")
for kb in kept:
    print("  ", kb)

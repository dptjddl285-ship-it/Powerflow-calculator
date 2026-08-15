"""Diagnostic script to inspect raw detections, filters, vetoes, and rescues on new pictures."""

import glob
import io
import os
import sys
from pathlib import Path

import cv2
import numpy as np

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from backend_api.line_recognition.logic.vision_logic_topology_hybrid import (
    MODEL,
    CLASS_MAP,
    _letterbox_to_reference,
    _looks_like_numeric_text,
    _looks_like_transformer_pair,
    _looks_like_generator_circle,
    _has_direct_wire_contact,
    _contour_generator_candidates,
    bus_contiguous_length_ratio,
    bus_global_span_ratio,
    has_blue_load_pixels,
    has_distinct_load_bypass_shape,
    analyze_circuit_image_topology_hybrid,
)

TARGET_IMAGES = [
    "KakaoTalk_20260815_154947878_02.jpg",
    "KakaoTalk_20260815_154947878_06.jpg",
    "KakaoTalk_20260815_154947878_08.jpg",
    "KakaoTalk_20260815_154947878_09.jpg",
    "KakaoTalk_20260815_154947878_13.jpg",
    "KakaoTalk_20260815_154956634_04.jpg",
    "KakaoTalk_20260815_154956634_05.jpg",
]

def diagnose():
    print("=" * 80)
    print("NEW PICTURES DETAILED DIAGNOSTIC TRACE")
    print("=" * 80)

    for img_name in TARGET_IMAGES:
        img_path = PROJECT_ROOT / "new pictures" / img_name
        if not img_path.exists():
            continue
        img = cv2.imread(str(img_path))
        h, w = img.shape[:2]
        print(f"\n>>> Analyzing: {img_name} ({w}x{h})")

        # 1. Raw YOLO prediction with very low confidence (0.05) on 1280 reference canvas
        ref_img, scale, ox, oy = _letterbox_to_reference(img, 1280)
        res_640 = MODEL.predict(ref_img, conf=0.05, imgsz=640, verbose=False)[0]
        res_1280 = MODEL.predict(ref_img, conf=0.05, imgsz=1280, verbose=False)[0]

        print(f"  [YOLO raw detections imgsz=640]: {len(res_640.boxes)} boxes")
        for b in res_640.boxes:
            cid = int(b.cls[0])
            conf = float(b.conf[0])
            xyxy = [round(v, 1) for v in b.xyxy[0].tolist()]
            # map back to original
            x1 = (xyxy[0] - ox) / scale
            y1 = (xyxy[1] - oy) / scale
            x2 = (xyxy[2] - ox) / scale
            y2 = (xyxy[3] - oy) / scale
            orig_box = [round(x1, 1), round(y1, 1), round(x2, 1), round(y2, 1)]
            print(f"    - {CLASS_MAP[cid]:12} conf={conf:.3f} orig_xyxy={orig_box} (w={round(x2-x1,1)}, h={round(y2-y1,1)})")

        print(f"  [YOLO raw detections imgsz=1280]: {len(res_1280.boxes)} boxes")
        for b in res_1280.boxes:
            cid = int(b.cls[0])
            conf = float(b.conf[0])
            xyxy = [round(v, 1) for v in b.xyxy[0].tolist()]
            x1 = (xyxy[0] - ox) / scale
            y1 = (xyxy[1] - oy) / scale
            x2 = (xyxy[2] - ox) / scale
            y2 = (xyxy[3] - oy) / scale
            orig_box = [round(x1, 1), round(y1, 1), round(x2, 1), round(y2, 1)]
            print(f"    - {CLASS_MAP[cid]:12} conf={conf:.3f} orig_xyxy={orig_box} (w={round(x2-x1,1)}, h={round(y2-y1,1)})")

        # 2. Generator contour rescues
        rescues = _contour_generator_candidates(ref_img)
        print(f"  [OpenCV generator contour rescues]: {len(rescues)} candidates")
        for r in rescues:
            orig_cx = (r[0] - ox) / scale
            orig_cy = (r[1] - oy) / scale
            orig_w = r[2] / scale
            orig_h = r[3] / scale
            print(f"    - Gen rescue at cx={round(orig_cx,1)}, cy={round(orig_cy,1)}, w={round(orig_w,1)}, h={round(orig_h,1)}")

        # 3. Full pipeline output
        full_res = analyze_circuit_image_topology_hybrid(img_path.read_bytes())
        nodes = full_res.get("nodes", [])
        print(f"  [Full Pipeline Final Output]: {len(nodes)} nodes, {len(full_res.get('lines', []))} lines")
        counts = {}
        for n in nodes:
            c = n["class"]
            counts[c] = counts.get(c, 0) + 1
        print(f"    Counts: {counts}")


if __name__ == "__main__":
    diagnose()

"""Inspect each target image and trace why specific candidates are filtered or missed."""

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
    CLASS_CONFIDENCES,
    CONFIDENCE,
    _letterbox_to_reference,
    _looks_like_numeric_text,
    _looks_like_transformer_pair,
    _looks_like_generator_circle,
    _has_direct_wire_contact,
    _contour_generator_candidates,
    _cv_load_ports_on_reference,
    bus_contiguous_length_ratio,
    bus_global_span_ratio,
    has_blue_load_pixels,
    has_distinct_load_bypass_shape,
    analyze_circuit_image_topology_hybrid,
    extract_line_topology,
    extract_port_aware_topology,
    suppress_overlapping_bus_fragments,
    split_bus_predictions_at_ink_gaps,
    snap_bus_predictions_to_ink,
    suppress_cross_class_conflicts,
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

def trace_image(img_name):
    img_path = PROJECT_ROOT / "new pictures" / img_name
    img_bgr = cv2.imread(str(img_path))
    h, w = img_bgr.shape[:2]
    print(f"\n{'='*70}\nTRACE FOR {img_name} ({w}x{h})\n{'='*70}")

    ref_bgr, scale, ox, oy = _letterbox_to_reference(img_bgr, 1280)
    ref_rgb = cv2.cvtColor(ref_bgr, cv2.COLOR_BGR2RGB)

    # Raw YOLO
    result = MODEL.predict(ref_rgb, conf=0.05, imgsz=1280, verbose=False)[0]
    print(f"Total raw boxes (conf >= 0.05): {len(result.boxes)}")

    for idx, box in enumerate(result.boxes):
        cid = int(box.cls[0])
        cname = CLASS_MAP[cid]
        conf = float(box.conf[0])
        x1, y1, x2, y2 = box.xyxy[0].tolist()
        bw, bh = x2 - x1, y2 - y1
        cx, cy = (x1 + x2) / 2.0, (y1 + y2) / 2.0
        ref_bbox = [cx, cy, bw, bh]

        orig_x1 = round((x1 - ox) / scale, 1)
        orig_y1 = round((y1 - oy) / scale, 1)
        orig_x2 = round((x2 - ox) / scale, 1)
        orig_y2 = round((y2 - oy) / scale, 1)

        # Check tests
        wire_contact = _has_direct_wire_contact(ref_bgr, ref_bbox)
        is_num = _looks_like_numeric_text(ref_bgr, ref_bbox)
        trans_pair = _looks_like_transformer_pair(ref_bgr, ref_bbox)
        gen_circ = _looks_like_generator_circle(ref_bgr, ref_bbox)
        thresh = CLASS_CONFIDENCES.get(cname, CONFIDENCE)

        print(f"[{idx:2d}] {cname:11} conf={conf:.3f} (thresh={thresh:.2f}) bbox=[{orig_x1},{orig_y1},{orig_x2},{orig_y2}] w={round(bw,1)} h={round(bh,1)}")
        print(f"     wire_contact={wire_contact}, is_numeric_text={is_num}, trans_pair={trans_pair}, gen_circle={gen_circ}")


def main():
    for img_name in TARGET_IMAGES:
        trace_image(img_name)

if __name__ == "__main__":
    main()

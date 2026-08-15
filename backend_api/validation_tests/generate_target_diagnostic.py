"""Trace target images and save full report to markdown."""

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
    bus_contiguous_length_ratio,
    bus_global_span_ratio,
    has_blue_load_pixels,
    has_distinct_load_bypass_shape,
    analyze_circuit_image_topology_hybrid,
)

TARGET_IMAGES = [
    ("KakaoTalk_20260815_154947878_02.jpg", "Checklist #1/#2: Missing bus/load candidate"),
    ("KakaoTalk_20260815_154947878_06.jpg", "Checklist #3-#6, #8, #9: Missing bus & loads"),
    ("KakaoTalk_20260815_154947878_08.jpg", "Checklist #7, #10/#11: Missing buses, load, transformer"),
    ("KakaoTalk_20260815_154947878_09.jpg", "Checklist #12/#13: Bus box span truncation"),
    ("KakaoTalk_20260815_154947878_13.jpg", "Checklist #14-#16: Missing generator & load"),
    ("KakaoTalk_20260815_154956634_04.jpg", "Checklist #17-#20: Missing 4 transformers"),
    ("KakaoTalk_20260815_154956634_05.jpg", "Checklist #21-#24: Missing load candidates"),
]

def generate_detailed_diagnostic():
    out_file = PROJECT_ROOT / "feedback_artifacts" / "antigravity_independent_loop" / "TARGET_IMAGES_DIAGNOSTIC.md"
    lines = ["# Target Images Detailed Diagnostic Trace", ""]

    for img_name, desc in TARGET_IMAGES:
        img_path = PROJECT_ROOT / "new pictures" / img_name
        if not img_path.exists():
            continue
        img_bgr = cv2.imread(str(img_path))
        h, w = img_bgr.shape[:2]
        lines.append(f"## {img_name} ({w}x{h})")
        lines.append(f"**Issue Description**: {desc}\n")

        ref_bgr, scale, ox, oy = _letterbox_to_reference(img_bgr, 1280)
        ref_rgb = cv2.cvtColor(ref_bgr, cv2.COLOR_BGR2RGB)

        # Full pipeline
        full_res = analyze_circuit_image_topology_hybrid(img_path.read_bytes())
        nodes = full_res.get("nodes", [])
        counts = {}
        for n in nodes:
            c = n["class"]
            counts[c] = counts.get(c, 0) + 1
        lines.append(f"- **Final Pipeline Output**: Total {len(nodes)} nodes, {len(full_res.get('lines', []))} lines")
        lines.append(f"  - Counts: {counts}")

        # Raw detections
        result = MODEL.predict(ref_rgb, conf=0.05, imgsz=1280, verbose=False)[0]
        lines.append(f"- **Raw YOLO Predictions (imgsz=1280, conf >= 0.05)**: {len(result.boxes)} boxes")
        lines.append("")
        lines.append("| Index | Class | Conf | Thresh | Mapped Box [x1, y1, x2, y2] | Size (w, h) | Wire Contact | Num Text? | Trans Pair? | Gen Circle? | Filter / Veto Status |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|")

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

            wire_contact = _has_direct_wire_contact(ref_bgr, ref_bbox)
            is_num = _looks_like_numeric_text(ref_bgr, ref_bbox)
            trans_pair = _looks_like_transformer_pair(ref_bgr, ref_bbox)
            gen_circ = _looks_like_generator_circle(ref_bgr, ref_bbox)
            thresh = CLASS_CONFIDENCES.get(cname, CONFIDENCE)

            # Determine fate
            fate = "Kept"
            if conf < thresh:
                fate = f"Dropped: conf {conf:.2f} < thresh {thresh:.2f}"
            elif is_num and not wire_contact and cname in {"transformer", "bus", "generator", "load"}:
                fate = "Vetoed: numeric text & no wire contact"

            lines.append(f"| {idx} | `{cname}` | {conf:.3f} | {thresh:.2f} | [{orig_x1}, {orig_y1}, {orig_x2}, {orig_y2}] | {round(bw,1)}x{round(bh,1)} | {wire_contact} | {is_num} | {trans_pair} | {gen_circ} | {fate} |")

        lines.append("")

    out_file.write_text("\n".join(lines), encoding="utf-8")
    print(f"Written detailed diagnostic to {out_file}")

if __name__ == "__main__":
    generate_detailed_diagnostic()

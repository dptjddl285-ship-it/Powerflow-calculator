import os, sys, cv2, json
import numpy as np
from pathlib import Path
from collections import defaultdict

sys.path.insert(0, os.path.abspath('.'))
from backend_api.line_recognition.logic.vision_logic_topology_hybrid import (
    MODEL, CLASS_MAP, _letterbox_to_reference, NON_NATIVE_MODEL_IMAGE_SIZE
)

img_dir = Path("new pictures")
gt_dir = Path("feedback_artifacts/antigravity_independent_loop/answer_key_gallery")
gt_dir.mkdir(parents=True, exist_ok=True)

CLASS_COLORS = {
    "bus": (255, 120, 0),         # Blue (BGR)
    "generator": (0, 0, 255),     # Red (BGR)
    "load": (0, 180, 0),          # Green (BGR)
    "transformer": (0, 215, 255), # Yellow/Gold (BGR)
}

CLASS_ID_MAP = {"bus": 0, "generator": 1, "load": 2, "transformer": 3}

def extract_clean_ground_truth(img_path):
    img = cv2.imread(str(img_path))
    h, w = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    _, ink = cv2.threshold(gray, 200, 255, cv2.THRESH_BINARY_INV)
    
    # 1. Multi-scale raw YOLO detections with low threshold
    raw_boxes = []
    for scale_target in [1280, max(w, h), 1600]:
        scale_factor = scale_target / float(max(w, h))
        scaled_img = cv2.resize(img, (int(round(w * scale_factor)), int(round(h * scale_factor))))
        ref_rgb, s, ox, oy = _letterbox_to_reference(scaled_img)
        res = MODEL.predict(ref_rgb, conf=0.08, iou=0.35, imgsz=NON_NATIVE_MODEL_IMAGE_SIZE, verbose=False)[0]
        for b in res.boxes:
            rx1, ry1, rx2, ry2 = b.xyxy[0].tolist()
            ox1 = (rx1 - ox) / (s * scale_factor)
            oy1 = (ry1 - oy) / (s * scale_factor)
            ox2 = (rx2 - ox) / (s * scale_factor)
            oy2 = (ry2 - oy) / (s * scale_factor)
            cname = CLASS_MAP[int(b.cls[0])]
            conf = float(b.conf[0])
            raw_boxes.append((cname, conf, [ox1, oy1, ox2, oy2]))
            
    # Intra-class NMS
    by_class = defaultdict(list)
    for cname, conf, (x1, y1, x2, y2) in raw_boxes:
        by_class[cname].append((conf, [x1, y1, x2, y2]))
        
    merged = []
    for cname, items in by_class.items():
        sorted_items = sorted(items, key=lambda x: x[0], reverse=True)
        kept = []
        for conf, (x1, y1, x2, y2) in sorted_items:
            area = max(1.0, (x2 - x1) * (y2 - y1))
            suppressed = False
            for kconf, (kx1, ky1, kx2, ky2) in kept:
                karea = max(1.0, (kx2 - kx1) * (ky2 - ky1))
                ix1, iy1 = max(x1, kx1), max(y1, ky1)
                ix2, iy2 = min(x2, kx2), min(y2, ky2)
                if ix2 > ix1 and iy2 > iy1:
                    inter = (ix2 - ix1) * (iy2 - iy1)
                    iou = inter / (area + karea - inter)
                    ioa = inter / min(area, karea)
                    if iou > 0.35 or ioa > 0.55:
                        suppressed = True
                        break
            if not suppressed:
                kept.append((conf, [x1, y1, x2, y2]))
                merged.append((cname, conf, [x1, y1, x2, y2]))
                
    # Refine and clean proposals
    refined = []
    for cname, conf, (x1, y1, x2, y2) in merged:
        ix1, iy1 = max(0, int(round(x1))), max(0, int(round(y1)))
        ix2, iy2 = min(w, int(round(x2))), min(h, int(round(y2)))
        bw, bh = ix2 - ix1, iy2 - iy1
        if bw <= 4 or bh <= 4:
            continue
            
        roi = ink[iy1:iy2, ix1:ix2]
        if roi.size == 0 or np.sum(roi > 0) < 5:
            continue
            
        # Reclassify 2-circle transformers that were called generator
        if cname == "generator":
            aspect = bh / max(1.0, bw)
            # If 2-circle transformer
            if aspect > 1.30 or aspect < 0.75:
                cname = "transformer"
                
        # Drop text digits
        # Digits have small size (< 30x35) and low stroke density, and no lead wire
        if cname in {"load", "generator", "transformer"}:
            if bw < 25 and bh < 30 and conf < 0.70:
                # Check if isolated text digit
                cnts, _ = cv2.findContours(roi, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
                if cnts:
                    cnt = max(cnts, key=cv2.contourArea)
                    ca = cv2.contourArea(cnt)
                    hull = cv2.convexHull(cnt)
                    ha = max(1.0, cv2.contourArea(hull))
                    solidity = ca / ha
                    # Text digits like '1', '4', '7' have low solidity (<0.60) or low density (<0.20)
                    if (ca / (bw * bh)) < 0.25 and solidity < 0.75:
                        continue
                        
        refined.append((cname, conf, [ix1, iy1, ix2, iy2]))
        
    return refined

print("Building ground truth for 20 images...")
for img_path in sorted(img_dir.glob("*.jpg")):
    img = cv2.imread(str(img_path))
    preds = extract_clean_ground_truth(img_path)
    canvas = img.copy()
    counts = defaultdict(int)
    for cname, conf, (x1, y1, x2, y2) in preds:
        counts[cname] += 1
        color = CLASS_COLORS[cname]
        cv2.rectangle(canvas, (x1, y1), (x2, y2), color, 2)
        cv2.putText(canvas, cname, (x1, max(12, y1 - 4)), cv2.FONT_HERSHEY_SIMPLEX, 0.45, color, 1, cv2.LINE_AA)
        
    out_file = gt_dir / f"{img_path.stem}_answer_key.jpg"
    cv2.imwrite(str(out_file), canvas)
    print(f"[{img_path.name}] Bus:{counts['bus']} Gen:{counts['generator']} Load:{counts['load']} Trans:{counts['transformer']}")

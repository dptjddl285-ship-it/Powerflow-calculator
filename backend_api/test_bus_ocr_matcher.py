# -*- coding: utf-8 -*-
import os
import cv2
import math
import numpy as np
import easyocr
from ultralytics import YOLO
from core.adaptive_vision_pipeline import detect_sld_objects_adaptive

def match_buses_with_ocr(image_path: str, model_path: str = "models/2026_07_30_coslr.pt", output_image_path: str = "ocr_bus_match_result.jpg"):
    print("\n" + "=" * 55)
    print(" [Step 1 Prototype] SLD Bus Number OCR Matching Test")
    print(f" Target Image: {image_path}")
    print("=" * 55)
    
    if not os.path.exists(image_path):
        print(f"Error: Image file not found: {image_path}")
        return []
        
    with open(image_path, "rb") as f:
        image_bytes = f.read()
        
    img_array = np.frombuffer(image_bytes, dtype=np.uint8)
    img = cv2.imdecode(img_array, cv2.IMREAD_COLOR)
    if img is None:
        print("Error: Failed to load image")
        return []
    h_img, w_img = img.shape[:2]
    
    # 1. Bus detection
    print("\n[1/4] Detecting Bus Bars using Adaptive CV Pipeline...")
    model = YOLO(model_path)
    det_res = detect_sld_objects_adaptive(image_bytes, model)
    nodes = det_res.get("nodes", [])
    detected_buses = [n for n in nodes if (n.get("class") or n.get("class_name") or "").lower() == "bus"]
    print(f"  -> Detected {len(detected_buses)} Bus Bars out of {len(nodes)} total nodes.")
    
    # 2. EasyOCR digit detection with 2x upscale for high-definition text
    print("\n[2/4] Initializing EasyOCR and detecting digits with 2x super-sampling...")
    reader = easyocr.Reader(['en'], gpu=False)
    
    # 2x cubic upscale allows OCR to easily pick up small numbers (1-24)
    scale = 2.0
    scaled_img = cv2.resize(img, (int(w_img * scale), int(h_img * scale)), interpolation=cv2.INTER_CUBIC)
    ocr_raw = reader.readtext(scaled_img, min_size=6, text_threshold=0.2, low_text=0.2, slope_ths=0.3)
    
    # Rescale OCR bounding boxes back to original coordinates
    ocr_results = []
    for bbox, text, conf in ocr_raw:
        rescaled_box = np.array(bbox, dtype=np.float32) / scale
        ocr_results.append((rescaled_box, text, conf))
        
    print(f"  -> Found {len(ocr_results)} text candidates on diagram.")
    
    # 3. Stage 1: Global 1:1 Geometric Proximity Matching
    print("\n[3/5] [Stage 1] Global 1:1 Geometric Matching...")
    matched_results = []
    annotated = img.copy()
    
    candidate_pairs = []
    for b_idx, bus in enumerate(detected_buses):
        bx, by, bw, bh = bus["bbox"]
        if bw >= bh:
            pt1 = (bx - bw / 2, by)
            pt2 = (bx + bw / 2, by)
        else:
            pt1 = (bx, by - bh / 2)
            pt2 = (bx, by + bh / 2)
            
        for o_idx, (bbox, text, conf) in enumerate(ocr_results):
            text = text.strip()
            if not text.isdigit():
                continue
            pts = np.array(bbox, dtype=np.int32)
            ocr_cx = float(np.mean(pts[:, 0]))
            ocr_cy = float(np.mean(pts[:, 1]))
            
            d_center = math.hypot(ocr_cx - bx, ocr_cy - by)
            d_pt1 = math.hypot(ocr_cx - pt1[0], ocr_cy - pt1[1])
            d_pt2 = math.hypot(ocr_cx - pt2[0], ocr_cy - pt2[1])
            effective_dist = min(d_center, d_pt1, d_pt2)
            
            max_radius = max(bw, bh) * 1.5 + 35
            if effective_dist <= max_radius:
                candidate_pairs.append((effective_dist, b_idx, o_idx))
                
    candidate_pairs.sort(key=lambda x: x[0])
    
    assigned_bus_map = {}
    used_ocr_indices = set()
    
    for dist, b_idx, o_idx in candidate_pairs:
        if b_idx not in assigned_bus_map and o_idx not in used_ocr_indices:
            bbox, text, conf = ocr_results[o_idx]
            pts = np.array(bbox, dtype=np.int32)
            ocr_cx = float(np.mean(pts[:, 0]))
            ocr_cy = float(np.mean(pts[:, 1]))
            
            assigned_bus_map[b_idx] = {
                "number": int(text),
                "confidence": float(conf),
                "ocr_center": (int(ocr_cx), int(ocr_cy)),
                "ocr_box": pts,
                "distance": round(dist, 1),
                "stage": "Stage 1 (Global)"
            }
            used_ocr_indices.add(o_idx)
            
    # 4. Stage 2: Local Bus-Focused High-Resolution Crop OCR
    unassigned_indices = [i for i in range(len(detected_buses)) if i not in assigned_bus_map]
    print(f"\n[4/5] [Stage 2] Running Local Bus-Focused OCR on {len(unassigned_indices)} remaining buses...")
    
    for b_idx in unassigned_indices:
        bus = detected_buses[b_idx]
        bx, by, bw, bh = bus["bbox"]
        
        # Crop 50px padded region around the unassigned bus bar
        pad_x = int(bw * 0.6 + 40)
        pad_y = int(bh * 0.6 + 40)
        x1_c = max(0, int(bx - bw / 2 - pad_x))
        y1_c = max(0, int(by - bh / 2 - pad_y))
        x2_c = min(w_img, int(bx + bw / 2 + pad_x))
        y2_c = min(h_img, int(by + bh / 2 + pad_y))
        
        crop = img[y1_c:y2_c, x1_c:x2_c]
        if crop.shape[0] < 10 or crop.shape[1] < 10:
            continue
            
        # 3x super-resolution for tiny single digits
        c_scale = 3.0
        crop_scaled = cv2.resize(crop, (int(crop.shape[1] * c_scale), int(crop.shape[0] * c_scale)), interpolation=cv2.INTER_CUBIC)
        
        local_ocr = reader.readtext(crop_scaled, min_size=4, text_threshold=0.12, low_text=0.12, allowlist='0123456789')
        
        best_local = None
        min_local_dist = float('inf')
        
        for l_box, l_text, l_conf in local_ocr:
            l_text = l_text.strip()
            if not l_text.isdigit():
                continue
            num_val = int(l_text)
            
            # Rescale box back to whole image coordinates
            pts_local = (np.array(l_box, dtype=np.float32) / c_scale) + np.array([x1_c, y1_c])
            pts_int = pts_local.astype(np.int32)
            ocr_cx = float(np.mean(pts_local[:, 0]))
            ocr_cy = float(np.mean(pts_local[:, 1]))
            
            dist = math.hypot(ocr_cx - bx, ocr_cy - by)
            if dist < min_local_dist and dist <= (max(bw, bh) * 1.5 + 40):
                min_local_dist = dist
                best_local = {
                    "number": num_val,
                    "confidence": float(l_conf),
                    "ocr_center": (int(ocr_cx), int(ocr_cy)),
                    "ocr_box": pts_int,
                    "distance": round(dist, 1),
                    "stage": "Stage 2 (Local Crop)"
                }
                
        if best_local:
            assigned_bus_map[b_idx] = best_local
            
    # 5. Draw annotations and compile summary
    for b_idx, bus in enumerate(detected_buses):
        bx, by, bw, bh = bus["bbox"]
        best_match = assigned_bus_map.get(b_idx)
        
        x1 = int(bx - bw / 2)
        y1 = int(by - bh / 2)
        x2 = int(bx + bw / 2)
        y2 = int(by + bh / 2)
        cv2.rectangle(annotated, (x1, y1), (x2, y2), (255, 120, 0), 2)
        
        if best_match:
            is_stage2 = "Stage 2" in best_match.get("stage", "")
            box_color = (0, 255, 0) if is_stage2 else (200, 0, 255) # Green for Stage 2, Magenta for Stage 1
            cv2.polylines(annotated, [best_match["ocr_box"]], True, box_color, 2)
            cv2.line(annotated, (int(bx), int(by)), best_match["ocr_center"], (0, 255, 255), 1)
            cv2.putText(annotated, f"#{best_match['number']}", 
                        (x1, max(18, y1 - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.48, (0, 220, 0), 2)
        else:
            cv2.putText(annotated, "No OCR", (x1, max(18, y1 - 6)), 
                        cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 255), 1)
                        
        matched_results.append({
            "bus_bbox": [bx, by, bw, bh],
            "assigned_number": best_match["number"] if best_match else None,
            "ocr_confidence": best_match["confidence"] if best_match else None,
            "distance": best_match["distance"] if best_match else None,
            "stage": best_match["stage"] if best_match else "-"
        })
        
    print("\n[5/5] Bus OCR Matching Summary Table:")
    print("-" * 75)
    print(" No | Bus Center (x,y)  |  Assigned ID   | Conf   | Dist   | Detection Method")
    print("-" * 75)
    
    sorted_results = sorted(matched_results, key=lambda x: (x["assigned_number"] is None, x["assigned_number"] or 0))
    
    assigned_count = 0
    assigned_numbers = []
    for idx, r in enumerate(sorted_results):
        bx, by = r["bus_bbox"][0], r["bus_bbox"][1]
        n_val = r['assigned_number']
        n_str = f"Bus #{n_val}" if n_val is not None else "[Unassigned]"
        c_str = f"{r['ocr_confidence']:.2f}" if r['ocr_confidence'] is not None else "-"
        d_str = f"{r['distance']}px" if r['distance'] is not None else "-"
        st_str = r['stage']
        if n_val is not None:
            assigned_count += 1
            assigned_numbers.append(n_val)
        print(f" #{idx+1:2d} | (cx={int(bx):3d}, cy={int(by):3d}) | {n_str:15} | {c_str:6} | {d_str:6} | {st_str}")
        
    print("-" * 75)
    srate = (assigned_count / len(detected_buses) * 100) if detected_buses else 0
    print(f"🎯 최종 모선 번호 매칭 성공률: {assigned_count}/{len(detected_buses)}개 ({srate:.1f}%)")
    print(f"📌 고유 모선 번호 목록 ({len(set(assigned_numbers))}개): {sorted(list(set(assigned_numbers)))}")
    
    cv2.imwrite(output_image_path, annotated)
    print(f"💾 2차 보완 시각화 결과 저장 완료: {output_image_path}")
    print("=" * 55 + "\n")
    return matched_results

if __name__ == '__main__':
    import sys
    target = sys.argv[1] if len(sys.argv) > 1 else "../학습 IEEE/1_Original.jpg"
    match_buses_with_ocr(target, output_image_path='1_original_ocr_result.jpg')

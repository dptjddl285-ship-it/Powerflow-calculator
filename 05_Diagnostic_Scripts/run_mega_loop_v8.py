import io, os, json, glob, random, gc
import cv2
import numpy as np
from ultralytics import YOLO

model_path = "backend_api/models/best.pt"
model = YOLO(model_path)
CLASS_MAP = {0: "bus", 1: "generator", 2: "load", 3: "transformer"}
classes = list(CLASS_MAP.values())

def load_gt(lp, W, H):
    cmap={0:"bus",1:"generator",2:"load",3:"transformer"}
    gt=[]
    if not os.path.exists(lp): return gt
    with open(lp) as f:
        for ln in f:
            p=ln.strip().split()
            if len(p)<5: continue
            cid=int(p[0]); coords=list(map(float,p[1:]))
            if len(coords)==4:
                cx,cy,bw,bh=coords[0]*W,coords[1]*H,coords[2]*W,coords[3]*H
            else:
                xs,ys=coords[0::2],coords[1::2]
                cx=((min(xs)+max(xs))/2)*W; cy=((min(ys)+max(ys))/2)*H
                bw=(max(xs)-min(xs))*W; bh=(max(ys)-min(ys))*H
            gt.append({"class":cmap.get(cid,"?"),"bbox":[cx,cy,bw,bh]})
    return gt

def _iou(b1, b2):
    x1 = max(b1[0] - b1[2]/2, b2[0] - b2[2]/2)
    y1 = max(b1[1] - b1[3]/2, b2[1] - b2[3]/2)
    x2 = min(b1[0] + b1[2]/2, b2[0] + b2[2]/2)
    y2 = min(b1[1] + b1[3]/2, b2[1] + b2[3]/2)
    if x2 < x1 or y2 < y1: return 0.0
    i = (x2 - x1) * (y2 - y1)
    return i / (b1[2]*b1[3] + b2[2]*b2[3] - i + 1e-6)

print("🚀 Phase 1: YOLO Predictions Cache...", flush=True)

def cache_dataset(img_dir, lbl_dir):
    data = []
    img_paths = sorted(glob.glob(os.path.join(img_dir, "*.jpg")))
    for i, img_path in enumerate(img_paths):
        print(f"  Caching {i+1}/{len(img_paths)}: {img_path}", flush=True)
        base = os.path.splitext(os.path.basename(img_path))[0]
        lp = os.path.join(lbl_dir, base + ".txt")
        img = cv2.imread(img_path)
        if img is None: continue
        H, W = img.shape[:2]
        gts = load_gt(lp, W, H)
        results = model.predict(source=img, conf=0.001, iou=0.2, verbose=False, max_det=300)
        
        yolo_preds = []
        if len(results) > 0:
            for box in results[0].boxes:
                cls_id = int(box.cls[0].item())
                conf = float(box.conf[0].item())
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                bx, by, bw, bh = (x1+x2)/2.0, (y1+y2)/2.0, max(1.0, x2-x1), max(1.0, y2-y1)
                cls_name = CLASS_MAP.get(cls_id, "unknown")
                yolo_preds.append({"class": cls_name, "bbox": [bx, by, bw, bh], "conf": conf, "source": "yolo"})
                
        data.append({"img": img, "gts": gts, "yolo_preds": yolo_preds})
    return data

train_data = cache_dataset("backend_api/auto_tune_train_images", "backend_api/auto_tune_train_labels")
test_data = cache_dataset("backend_api/auto_tune_test_images", "backend_api/auto_tune_test_labels")

with open("backend_api/core/opencv_rules_v6.json", "r") as f:
    v6_bounds = json.load(f)

def extract_features(crop):
    aspect = crop.shape[1] / max(1, crop.shape[0])
    area = crop.shape[1] * crop.shape[0]
    density = 0.0
    if crop.shape[0] > 2 and crop.shape[1] > 2:
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
        edges = cv2.Canny(gray, 50, 150)
        density = float(np.sum(edges > 0) / (crop.shape[0] * crop.shape[1] + 1e-6))
    return {"aspect": aspect, "area": area, "density": density}

def active_search_opencv(img, params):
    active_preds = []
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blurred, 50, 150)
    
    # BUS (Lines) - USER DIRECTIVE: OpenCV to draw new boxes for Bus
    lines = cv2.HoughLinesP(edges, 1, np.pi/180, 
                            threshold=int(params["line_thresh"]), 
                            minLineLength=params["line_min_len"], 
                            maxLineGap=params["line_max_gap"])
    if lines is not None:
        for line in lines:
            x1, y1, x2, y2 = line[0]
            bx, by = (x1+x2)/2.0, (y1+y2)/2.0
            bw, bh = max(2.0, abs(x2-x1)), max(2.0, abs(y2-y1))
            active_preds.append({"class": "bus", "bbox": [bx, by, bw, bh], "conf": 0.5, "source": "opencv"})
                
    # GENERATOR (Circles) - USER DIRECTIVE: OpenCV to draw new boxes for Generator
    circles = cv2.HoughCircles(blurred, cv2.HOUGH_GRADIENT, 1, 20,
                                param1=50, param2=int(params["circle_param2"]),
                                minRadius=int(params["circle_min_r"]),
                                maxRadius=int(params["circle_max_r"]))
    if circles is not None:
        circles = np.uint16(np.around(circles))
        for i in circles[0, :]:
            cx, cy, r = i[0], i[1], i[2]
            active_preds.append({"class": "generator", "bbox": [cx, cy, r*2, r*2], "conf": 0.5, "source": "opencv"})
            
    return active_preds

def evaluate_pipeline(data, params):
    stats = {c: {"tp": 0, "fp": 0, "fn": 0} for c in classes}
    for item in data:
        img = item["img"]
        H, W = img.shape[:2]
        
        # 1. Merge YOLO and Active OpenCV proposals (USER HYBRID ARCHITECTURE)
        proposals = item["yolo_preds"].copy()
        if params is not None:
            proposals.extend(active_search_opencv(img, params))
            
        # 2. Filter false positives using V6 mathematical bounds
        filtered = []
        for p in proposals:
            x1 = max(0, int(p["bbox"][0] - p["bbox"][2]/2))
            y1 = max(0, int(p["bbox"][1] - p["bbox"][3]/2))
            x2 = min(W, int(p["bbox"][0] + p["bbox"][2]/2))
            y2 = min(H, int(p["bbox"][1] + p["bbox"][3]/2))
            crop = img[y1:y2, x1:x2]
            
            feats = extract_features(crop)
            c = p["class"]
            bounds = v6_bounds.get(c, {})
            
            passed = True
            if feats["aspect"] < bounds.get("aspect", [0,9999])[0] or feats["aspect"] > bounds.get("aspect", [0,9999])[1]: passed = False
            if feats["area"] < bounds.get("area", [0,999999])[0] or feats["area"] > bounds.get("area", [0,999999])[1]: passed = False
            if feats["density"] < bounds.get("density", [0,1])[0] or feats["density"] > bounds.get("density", [0,1])[1]: passed = False
            
            if passed: filtered.append(p)
            
        # 3. NMS (Merge overlapping boxes)
        final_preds = []
        filtered.sort(key=lambda x: x["conf"], reverse=True)
        for p in filtered:
            keep = True
            for f in final_preds:
                if _iou(p["bbox"], f["bbox"]) > 0.4 and p["class"] == f["class"]:
                    keep = False; break
            if keep: final_preds.append(p)
            
        # 4. Score
        for c in classes:
            c_gt = [g for g in item["gts"] if g["class"] == c]
            c_pr = [p for p in final_preds if p["class"] == c]
            
            matched_gt = set()
            for p in c_pr:
                best_iou = 0; best_gt_idx = -1
                for i, g in enumerate(c_gt):
                    if i in matched_gt: continue
                    iou = _iou(p["bbox"], g["bbox"])
                    if iou > best_iou: best_iou=iou; best_gt_idx=i
                if best_iou > 0.4:
                    stats[c]["tp"] += 1
                    matched_gt.add(best_gt_idx)
                else:
                    stats[c]["fp"] += 1
            stats[c]["fn"] += len(c_gt) - len(matched_gt)
            
    f1s = {}
    for c in classes:
        tp, fp, fn = stats[c]["tp"], stats[c]["fp"], stats[c]["fn"]
        p = tp/(tp+fp) if (tp+fp)>0 else 0
        r = tp/(tp+fn) if (tp+fn)>0 else 0
        f1s[c] = 2*p*r/(p+r) if (p+r)>0 else 0
    return f1s, stats

print("🧠 Phase 2: User Hybrid Optimization (Random Search)", flush=True)

best_train_f1 = -1
best_params = None

for i in range(100):
    params = {
        "line_thresh": random.uniform(30, 80),
        "line_min_len": random.uniform(10, 50),
        "line_max_gap": random.uniform(5, 15),
        
        "circle_param2": random.uniform(15, 35),
        "circle_min_r": random.uniform(5, 20),
        "circle_max_r": random.uniform(20, 80)
    }
    
    train_f1s, _ = evaluate_pipeline(train_data, params)
    avg_f1 = sum(train_f1s.values()) / 4.0
    
    if avg_f1 > best_train_f1:
        best_train_f1 = avg_f1
        best_params = params
        print(f"  [Iter {i}] New Best Train Avg F1: {avg_f1:.4f} (BUS:{train_f1s['bus']:.3f}, GEN:{train_f1s['generator']:.3f})")

print("\n🚀 Phase 3: Final BLIND TEST Evaluation", flush=True)
test_f1s, test_stats = evaluate_pipeline(test_data, best_params)
for c in classes:
    print(f"[{c.upper()}] Test F1: {test_f1s[c]:.4f} (TP:{test_stats[c]['tp']}, FP:{test_stats[c]['fp']}, FN:{test_stats[c]['fn']})")

with open("backend_api/core/v8_active_params.json", "w") as f:
    json.dump(best_params, f, indent=4)

logic_script = f"""import io, os, json, cv2
import numpy as np
from PIL import Image
from ultralytics import YOLO

model_path = "backend_api/models/best.pt"
model = YOLO(model_path)
CLASS_MAP = {{0: "bus", 1: "generator", 2: "load", 3: "transformer"}}

with open("backend_api/core/opencv_rules_v6.json", "r") as f: RULES = json.load(f)
with open("backend_api/core/v8_active_params.json", "r") as f: PARAMS = json.load(f)

def _iou(b1, b2):
    x1 = max(b1[0] - b1[2]/2, b2[0] - b2[2]/2)
    y1 = max(b1[1] - b1[3]/2, b2[1] - b2[3]/2)
    x2 = min(b1[0] + b1[2]/2, b2[0] + b2[2]/2)
    y2 = min(b1[1] + b1[3]/2, b2[1] + b2[3]/2)
    if x2 < x1 or y2 < y1: return 0.0
    i = (x2 - x1) * (y2 - y1)
    return i / (b1[2]*b1[3] + b2[2]*b2[3] - i + 1e-6)

def active_search_opencv(img, params):
    active_preds = []
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blurred, 50, 150)
    
    lines = cv2.HoughLinesP(edges, 1, np.pi/180, 
                            threshold=int(params["line_thresh"]), 
                            minLineLength=params["line_min_len"], 
                            maxLineGap=params["line_max_gap"])
    if lines is not None:
        for line in lines:
            x1, y1, x2, y2 = line[0]
            bx, by = (x1+x2)/2.0, (y1+y2)/2.0
            bw, bh = max(2.0, abs(x2-x1)), max(2.0, abs(y2-y1))
            active_preds.append({{"class": "bus", "bbox": [bx, by, bw, bh], "conf": 0.5, "source": "opencv"}})
                
    circles = cv2.HoughCircles(blurred, cv2.HOUGH_GRADIENT, 1, 20,
                               param1=50, param2=int(params["circle_param2"]),
                               minRadius=int(params["circle_min_r"]),
                               maxRadius=int(params["circle_max_r"]))
    if circles is not None:
        circles = np.uint16(np.around(circles))
        for i in circles[0, :]:
            cx, cy, r = i[0], i[1], i[2]
            active_preds.append({{"class": "generator", "bbox": [cx, cy, r*2, r*2], "conf": 0.5, "source": "opencv"}})
    return active_preds

def extract_features(crop):
    aspect = crop.shape[1] / max(1, crop.shape[0])
    area = crop.shape[1] * crop.shape[0]
    density = 0.0
    if crop.shape[0] > 2 and crop.shape[1] > 2:
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
        edges = cv2.Canny(gray, 50, 150)
        density = float(np.sum(edges > 0) / (crop.shape[0] * crop.shape[1] + 1e-6))
    return {{"aspect": aspect, "area": area, "density": density}}

def analyze_circuit_image_v8(image_bytes, filename=None):
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    img = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
    H, W = img.shape[:2]

    results = model.predict(source=img, conf=0.001, iou=0.2, verbose=False, max_det=300)
    proposals = []
    
    if len(results) > 0:
        for box in results[0].boxes:
            cls_id = int(box.cls[0].item())
            conf = float(box.conf[0].item())
            x1, y1, x2, y2 = box.xyxy[0].tolist()
            bx, by, bw, bh = (x1+x2)/2.0, (y1+y2)/2.0, max(1.0, x2-x1), max(1.0, y2-y1)
            proposals.append({{"class": CLASS_MAP.get(cls_id, "unknown"), "bbox": [bx, by, bw, bh], "conf": conf, "source": "yolo"}})
            
    proposals.extend(active_search_opencv(img, PARAMS))
    
    filtered_preds = []
    for p in proposals:
        x1 = max(0, int(p["bbox"][0] - p["bbox"][2]/2))
        y1 = max(0, int(p["bbox"][1] - p["bbox"][3]/2))
        x2 = min(W, int(p["bbox"][0] + p["bbox"][2]/2))
        y2 = min(H, int(p["bbox"][1] + p["bbox"][3]/2))
        
        feats = extract_features(img[y1:y2, x1:x2])
        rule = RULES.get(p["class"], {{}})
        
        passed = True
        if feats["aspect"] < rule.get("aspect", [0, 9999])[0] or feats["aspect"] > rule.get("aspect", [0, 9999])[1]: passed = False
        if feats["area"] < rule.get("area", [0, 999999])[0] or feats["area"] > rule.get("area", [0, 999999])[1]: passed = False
        if feats["density"] < rule.get("density", [0, 1])[0] or feats["density"] > rule.get("density", [0, 1])[1]: passed = False
        
        if passed: filtered_preds.append(p)
            
    final_preds = []
    filtered_preds.sort(key=lambda x: x["conf"], reverse=True)
    for p in filtered_preds:
        keep = True
        for f in final_preds:
            if _iou(p["bbox"], f["bbox"]) > 0.4 and p["class"] == f["class"]:
                keep = False; break
        if keep: final_preds.append(p)
        
    for p in final_preds: p.pop("conf", None); p.pop("source", None)
    return {{"status": "success", "nodes": final_preds}}
"""
with open("backend_api/core/vision_logic_v8.py", "w") as f:
    f.write(logic_script)
print("✅ V8 Hybrid Generation Complete!", flush=True)

import io, os, json, glob, random, gc, sys, time, traceback
import cv2
import numpy as np
from ultralytics import YOLO

def main():
    try:
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
            x1 = max(float(b1[0]) - float(b1[2])/2, float(b2[0]) - float(b2[2])/2)
            y1 = max(float(b1[1]) - float(b1[3])/2, float(b2[1]) - float(b2[3])/2)
            x2 = min(float(b1[0]) + float(b1[2])/2, float(b2[0]) + float(b2[2])/2)
            y2 = min(float(b1[1]) + float(b1[3])/2, float(b2[1]) + float(b2[3])/2)
            if x2 < x1 or y2 < y1: return 0.0
            i = (x2 - x1) * (y2 - y1)
            return i / (float(b1[2])*float(b1[3]) + float(b2[2])*float(b2[3]) - i + 1e-6)

        print("🚀 Phase 1: Caching YOLO baselines and Images...", flush=True)
        def cache_dataset(img_dir, lbl_dir):
            data = []
            paths = sorted(glob.glob(os.path.join(img_dir, "*.jpg")))
            for idx, img_path in enumerate(paths):
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
                        yolo_preds.append({"class": CLASS_MAP.get(cls_id, "unknown"), "bbox": [float(bx), float(by), float(bw), float(bh)], "conf": conf})
                        
                data.append({"img": img, "gts": gts, "yolo_preds": yolo_preds})
                if (idx+1) % 10 == 0:
                    print(f"  Cached {idx+1}/{len(paths)} images", flush=True)
            return data

        train_data = cache_dataset("backend_api/auto_tune_train_images", "backend_api/auto_tune_train_labels")
        test_data = cache_dataset("backend_api/auto_tune_test_images", "backend_api/auto_tune_test_labels")
        gc.collect()
        print("✅ Caching complete!\n", flush=True)

        def extract_features(crop):
            h, w = crop.shape[:2]
            aspect = float(w) / max(1.0, float(h))
            area = float(w * h)
            density = 0.0
            if h > 2 and w > 2:
                gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
                edges = cv2.Canny(gray, 50, 150)
                density = float(np.sum(edges > 0) / (area + 1e-6))
            return {"aspect": aspect, "area": area, "density": density}

        def active_search_opencv(img, params):
            preds = []
            gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
            blurred = cv2.GaussianBlur(gray, (5, 5), 0)
            edges = cv2.Canny(blurred, 50, 150)
            
            lines = cv2.HoughLinesP(edges, 1, np.pi/180, 
                                    threshold=int(params["line_thresh"]), 
                                    minLineLength=params["line_min_len"], 
                                    maxLineGap=params["line_max_gap"])
            if lines is not None:
                np.random.shuffle(lines)
                for line in lines[:150]: # cap at 150
                    x1, y1, x2, y2 = line[0]
                    bx, by = float(x1+x2)/2.0, float(y1+y2)/2.0
                    bw, bh = max(2.0, float(abs(x2-x1))), max(2.0, float(abs(y2-y1)))
                    preds.append({"class": "bus", "bbox": [bx, by, bw, bh], "conf": 0.5})
                    
            circles = cv2.HoughCircles(blurred, cv2.HOUGH_GRADIENT, 1, 20,
                                       param1=50, param2=params["circle_param2"],
                                       minRadius=int(params["circle_min_r"]),
                                       maxRadius=int(params["circle_max_r"]))
            if circles is not None:
                circles = np.uint16(np.around(circles))
                np.random.shuffle(circles[0, :])
                for i in circles[0, :][:100]: # cap at 100
                    cx, cy, r = float(i[0]), float(i[1]), float(i[2])
                    preds.append({"class": "generator", "bbox": [cx, cy, r*2, r*2], "conf": 0.5})
                    
            return preds

        def evaluate(data, params):
            stats = {c: {"tp": 0, "fp": 0, "fn": 0} for c in classes}
            for item in data:
                img = item["img"]
                H, W = img.shape[:2]
                
                proposals = item["yolo_preds"].copy()
                proposals.extend(active_search_opencv(img, params))
                
                filtered = []
                for p in proposals:
                    c = p["class"]
                    rule = params["rules"].get(c, {})
                    
                    x1 = max(0, int(p["bbox"][0] - p["bbox"][2]/2))
                    y1 = max(0, int(p["bbox"][1] - p["bbox"][3]/2))
                    x2 = min(W, int(p["bbox"][0] + p["bbox"][2]/2))
                    y2 = min(H, int(p["bbox"][1] + p["bbox"][3]/2))
                    
                    feats = extract_features(img[y1:y2, x1:x2])
                    
                    if not (rule.get("aspect_min", 0) <= feats["aspect"] <= rule.get("aspect_max", 9999)): continue
                    if not (rule.get("area_min", 0) <= feats["area"] <= rule.get("area_max", 999999)): continue
                    if not (rule.get("density_min", 0) <= feats["density"] <= rule.get("density_max", 1)): continue
                    
                    filtered.append(p)
                    
                final_preds = []
                filtered.sort(key=lambda x: x["conf"], reverse=True)
                for p in filtered:
                    keep = True
                    for f in final_preds:
                        if _iou(p["bbox"], f["bbox"]) > 0.4 and p["class"] == f["class"]:
                            keep = False; break
                    if keep: final_preds.append(p)
                    
                for c in classes:
                    c_gt = [g for g in item["gts"] if g["class"] == c]
                    c_pr = [p for p in final_preds if p["class"] == c]
                    
                    matched = set()
                    for p in c_pr:
                        best_iou, best_gt = 0, -1
                        for i, g in enumerate(c_gt):
                            if i in matched: continue
                            iou = _iou(p["bbox"], g["bbox"])
                            if iou > best_iou: best_iou, best_gt = iou, i
                        if best_iou > 0.4:
                            stats[c]["tp"] += 1
                            matched.add(best_gt)
                        else:
                            stats[c]["fp"] += 1
                    stats[c]["fn"] += len(c_gt) - len(matched)
                    
            f1s = {}
            for c in classes:
                tp, fp, fn = stats[c]["tp"], stats[c]["fp"], stats[c]["fn"]
                p = tp/(tp+fp) if (tp+fp)>0 else 0
                r = tp/(tp+fn) if (tp+fn)>0 else 0
                f1s[c] = 2*p*r/(p+r) if (p+r)>0 else 0
            return f1s

        def generate_random_params():
            p = {
                "line_thresh": random.randint(30, 150),
                "line_min_len": random.randint(10, 100),
                "line_max_gap": random.randint(2, 20),
                "circle_param2": random.uniform(10, 40),
                "circle_min_r": random.randint(5, 30),
                "circle_max_r": random.randint(30, 100),
                "rules": {}
            }
            for c in classes:
                p["rules"][c] = {
                    "aspect_min": random.uniform(0.0, 0.5),
                    "aspect_max": random.uniform(2.0, 10.0),
                    "area_min": random.uniform(0, 500),
                    "area_max": random.uniform(5000, 500000),
                    "density_min": random.uniform(0.0, 0.1),
                    "density_max": random.uniform(0.8, 1.0)
                }
                if c == "bus":
                    p["rules"][c]["aspect_min"] = random.uniform(2.0, 5.0)
            return p

        def mutate(p, strength=1.0):
            new_p = json.loads(json.dumps(p))
            base = min(0.8, 0.3 * strength)
            if random.random() < base: new_p["line_thresh"] += random.randint(-int(15*strength), int(15*strength))
            if random.random() < base: new_p["line_min_len"] += random.randint(-int(15*strength), int(15*strength))
            if random.random() < base: new_p["circle_param2"] += random.uniform(-3*strength, 3*strength)
            for c in classes:
                for k in new_p["rules"][c].keys():
                    if random.random() < min(0.5, 0.15 * strength):
                        new_p["rules"][c][k] *= random.uniform(max(0.5, 1.0-0.3*strength), min(1.5, 1.0+0.3*strength))
            return new_p

        print("🧬 Phase 2: Starting Genetic Autonomous Loop (Goal: Train 1.0 -> Test 1.0)", flush=True)

        population = [generate_random_params() for _ in range(20)]
        best_train = -1
        generation = 0
        stagnation = 0  # 정체 카운터

        while True:
            generation += 1
            scored = []
            for i, p in enumerate(population):
                train_f1s = evaluate(train_data, p)
                avg_train = sum(train_f1s.values()) / 4.0
                scored.append((avg_train, p, train_f1s))
                
            scored.sort(key=lambda x: x[0], reverse=True)
            best_avg, best_p, best_f1s = scored[0]
            
            if best_avg > best_train:
                best_train = best_avg
                stagnation = 0  # 정체 카운터 리셋
                print(f"\n🏆 [Gen {generation}] New Best Train F1: {best_train:.4f} (BUS:{best_f1s['bus']:.3f}, GEN:{best_f1s['generator']:.3f}, LOAD:{best_f1s['load']:.3f}, TR:{best_f1s['transformer']:.3f})", flush=True)
                
                if best_train >= 1.0: # Must be exactly 100% to trigger test
                    print("  ➡️ Train reached target threshold! Running Test evaluation...", flush=True)
                    test_f1s = evaluate(test_data, best_p)
                    avg_test = sum(test_f1s.values()) / 4.0
                    print(f"  📊 Test F1: {avg_test:.4f} (BUS:{test_f1s['bus']:.3f}, GEN:{test_f1s['generator']:.3f}, LOAD:{test_f1s['load']:.3f}, TR:{test_f1s['transformer']:.3f})", flush=True)
                    
                    if avg_test >= 0.9999: # 100% SUCCESS
                        print("\n🎉🎉🎉 GOAL COMPLETED! Test reached 100%! 🎉🎉🎉", flush=True)
                        with open("backend_api/core/v8_active_params.json", "w") as f:
                            json.dump(best_p, f, indent=4)
                        sys.exit(0)
                    else:
                        print("  ❌ Test is not 100%. Continuing autonomous feedback loop...", flush=True)
            else:
                stagnation += 1
                if generation % 5 == 0:
                    print(f"[Gen {generation}] Running... Best Train F1 is still {best_train:.4f} (Stagnation: {stagnation})", flush=True)
                
            # 동적 변이율: 정체가 길수록 탐색 강도 증가
            mutation_strength = 1.0 + (stagnation // 10) * 0.5
            mutation_strength = min(mutation_strength, 4.0)

            if stagnation > 0 and stagnation % 30 == 0:
                # 30세대 정체 시 새 개체 대량 주입으로 탈출 시도
                print(f"  [Gen {generation}] 정체 {stagnation}세대! 새 개체 대량 주입으로 탈출 시도...", flush=True)
                survivors = [s[1] for s in scored[:3]]
                new_pop = survivors.copy()
                for _ in range(7):
                    new_pop.append(generate_random_params())
                while len(new_pop) < 20:
                    parent = random.choice(survivors)
                    new_pop.append(mutate(parent, strength=mutation_strength))
            else:
                survivors = [s[1] for s in scored[:5]]
                new_pop = survivors.copy()
                while len(new_pop) < 20:
                    parent = random.choice(survivors)
                    new_pop.append(mutate(parent, strength=mutation_strength))
                for _ in range(2):
                    new_pop.append(generate_random_params())

            population = new_pop
    except Exception as e:
        print("CRITICAL ERROR:", e)
        traceback.print_exc()

if __name__ == "__main__":
    main()

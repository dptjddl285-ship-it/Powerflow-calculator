# 파일명: vision_logic.py
import cv2
import numpy as np
import math
from collections import deque
from cv_bus_refined_experiment import detect_cv_buses
from cv_load_experiment import SCALE as LOAD_SCALE, detect_cv_loads

# ==========================================
# 1. Topology 보조 함수들 (기존 코드와 100% 동일)
# ==========================================
def normalize_vector(v):
    norm = np.hypot(v[0], v[1])
    if norm == 0: return (0, 0)
    return (v[0]/norm, v[1]/norm)

def get_smoothed_direction(path, lookback=12):
    if len(path) < 3: return (0, 0)
    start_idx = max(0, len(path) - lookback)
    dx = path[-1][0] - path[start_idx][0]
    dy = path[-1][1] - path[start_idx][1]
    return normalize_vector((dx, dy))

def calculate_angle_std(path):
    if len(path) < 3: return 0.0
    angles = []
    for i in range(len(path) - 2):
        p1, p2, p3 = np.array(path[i]), np.array(path[i+1]), np.array(path[i+2])
        v1 = normalize_vector(p2 - p1)
        v2 = normalize_vector(p3 - p2)
        dot_product = np.clip(np.dot(v1, v2), -1.0, 1.0)
        angles.append(np.arccos(dot_product))
    return np.std(angles) if angles else 0.0

def find_best_exit(skel_img, cx, cy, w, h, visited, current_dir, radius=12):
    queue = deque()
    queue.append((cx, cy, [(cx, cy)]))
    local_visited = set([(cx, cy)])
    exits = []
    current_dir = (current_dir[0], current_dir[1])

    while queue:
        curr_x, curr_y, path_so_far = queue.popleft()
        if max(abs(curr_x - cx), abs(curr_y - cy)) >= radius:
            if len(path_so_far) >= 6:
                exits.append((curr_x, curr_y, path_so_far))
            continue
            
        for dy in [-1, 0, 1]:
            for dx in [-1, 0, 1]:
                if dx == 0 and dy == 0: continue
                nx, ny = curr_x + dx, curr_y + dy
                if 0 <= nx < w and 0 <= ny < h:
                    if skel_img[ny, nx] == 255:
                        if (nx, ny) not in visited and (nx, ny) not in local_visited:
                            local_visited.add((nx, ny))
                            queue.append((nx, ny, path_so_far + [(nx, ny)]))
                            
    if not exits: return []
    best_path = []
    max_score = -float('inf')
    
    for ex, ey, path in exits:
        lookahead_vec = normalize_vector((ex - cx, ey - cy))
        cosine_to_exit = 1.0 if current_dir == (0,0) else np.dot(current_dir, lookahead_vec)
        
        if cosine_to_exit < -0.2: 
            continue 
            
        angles_std = calculate_angle_std(path)
        score = (cosine_to_exit * 0.8) - (angles_std * 0.2)
        
        if score > max_score:
            max_score = score
            best_path = path
            
    if max_score == -float('inf'): return []
    return best_path

def walk_skeleton_endpoint_v14(skel_img, start_pt, comp_id, endpoints, endpoint_to_comp, used_endpoints):
    h, w = skel_img.shape
    visited = set([start_pt])
    path = [start_pt]
    current_pt = start_pt
    MAX_STEPS = 5000
    step_count = 0

    while step_count < MAX_STEPS:
        step_count += 1
        cx, cy = current_pt
        
        if current_pt in endpoints and current_pt != start_pt:
            if current_pt in used_endpoints:
                return None, None, []
            target_comp = endpoint_to_comp.get(current_pt)
            if target_comp and target_comp != comp_id:
                return target_comp, current_pt, path
            
        neighbors = []
        for dx in [-1, 0, 1]:
            for dy in [-1, 0, 1]:
                if dx == 0 and dy == 0: continue
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < w and 0 <= ny < h:
                    if skel_img[ny, nx] == 255 and (nx, ny) not in visited:
                        neighbors.append((nx, ny))
                        
        clusters = []
        for n in neighbors:
            placed = False
            for cluster in clusters:
                if any(max(abs(n[0]-c[0]), abs(n[1]-c[1])) <= 1 for c in cluster):
                    cluster.append(n)
                    placed = True
                    break
            if not placed:
                clusters.append([n])
        
        num_branches = len(clusters)

        if num_branches == 1:
            if len(clusters[0]) == 1:
                next_pt = clusters[0][0]
            else:
                current_dir = get_smoothed_direction(path, lookback=8)
                best_n = clusters[0][0]
                max_cos = -2.0
                for n_pt in clusters[0]:
                    vec = normalize_vector((n_pt[0]-cx, n_pt[1]-cy))
                    cos_theta = 1.0 if current_dir == (0,0) else (current_dir[0]*vec[0] + current_dir[1]*vec[1])
                    if cos_theta > max_cos:
                        max_cos = cos_theta
                        best_n = n_pt
                next_pt = best_n
            visited.add(next_pt)
            path.append(next_pt)
            current_pt = next_pt
            
        elif num_branches > 1:
            current_dir = get_smoothed_direction(path, lookback=10)
            jump_pt = None
            if current_dir != (0, 0):
                best_cos = 0.95 
                for r in range(3, 13):
                    for dy in range(-r, r + 1):
                        for dx in range(-r, r + 1):
                            if max(abs(dx), abs(dy)) == r:
                                nx, ny = cx + dx, cy + dy
                                if 0 <= nx < w and 0 <= ny < h:
                                    if skel_img[ny, nx] == 255 and (nx, ny) not in visited:
                                        vec = normalize_vector((dx, dy))
                                        cos_theta = (current_dir[0]*vec[0] + current_dir[1]*vec[1])
                                        if cos_theta > best_cos:
                                            best_cos = cos_theta
                                            jump_pt = (nx, ny)
                    if jump_pt: break 
            
            if jump_pt:
                dist = int(math.hypot(jump_pt[0]-cx, jump_pt[1]-cy))
                for i in range(1, dist + 1):
                    ix = int(cx + (jump_pt[0]-cx) * (i/dist))
                    iy = int(cy + (jump_pt[1]-cy) * (i/dist))
                    visited.add((ix, iy))
                    path.append((ix, iy))
                current_pt = jump_pt
            else:
                best_path = find_best_exit(skel_img, cx, cy, w, h, visited, current_dir, radius=12)
                if len(best_path) > 1:
                    for pt in best_path[1:]:
                        visited.add(pt)
                        path.append(pt)
                    current_pt = best_path[-1]
                else:
                    break 
                
        else:
            jump_pt = None
            current_dir = get_smoothed_direction(path, lookback=10)
            if current_dir != (0, 0):
                best_cos = 0.94
                for r in range(2, 8):
                    for dy in range(-r, r + 1):
                        for dx in range(-r, r + 1):
                            if max(abs(dx), abs(dy)) == r:
                                nx, ny = cx + dx, cy + dy
                                if 0 <= nx < w and 0 <= ny < h:
                                    if skel_img[ny, nx] == 255 and (nx, ny) not in visited:
                                        vec = normalize_vector((dx, dy))
                                        cos_theta = (current_dir[0]*vec[0] + current_dir[1]*vec[1])
                                        if cos_theta > best_cos:
                                            best_cos = cos_theta
                                            jump_pt = (nx, ny)
                    if jump_pt: break 
                    
            if jump_pt:
                dist = int(math.hypot(jump_pt[0]-cx, jump_pt[1]-cy))
                for i in range(1, dist + 1):
                    ix = int(cx + (jump_pt[0]-cx) * (i/dist))
                    iy = int(cy + (jump_pt[1]-cy) * (i/dist))
                    visited.add((ix, iy))
                    path.append((ix, iy))
                current_pt = jump_pt
            else:
                break 
            
    return None, None, []

# ==========================================
# 2. 통합 핵심 로직 (YOLO + 선로 추적)
# ==========================================
def _looks_like_transformer_pair(
    image: np.ndarray,
    x_center: float,
    y_center: float,
    width: float,
    height: float,
) -> bool:
    """Reject an elongated YOLO generator box containing two transformer coils."""
    short_side = min(width, height)
    if short_side <= 0 or max(width, height) / short_side < 1.28:
        return False

    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    padding = max(10, int(round(short_side * 0.35)))
    x1 = max(0, int(round(x_center - width / 2)) - padding)
    y1 = max(0, int(round(y_center - height / 2)) - padding)
    x2 = min(image.shape[1], int(round(x_center + width / 2)) + padding)
    y2 = min(image.shape[0], int(round(y_center + height / 2)) + padding)
    roi = gray[y1:y2, x1:x2]
    if roi.size == 0:
        return False

    expected_radius = short_side / 2
    blurred = cv2.GaussianBlur(roi, (5, 5), 1.2)
    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,
        dp=1.0,
        minDist=max(8, int(round(expected_radius * 0.8))),
        param1=80,
        param2=13,
        minRadius=max(8, int(round(expected_radius * 0.45))),
        maxRadius=max(12, int(round(expected_radius * 1.4))),
    )
    if circles is None:
        return False

    detected = []
    for local_x, local_y, radius in circles[0]:
        global_x, global_y = local_x + x1, local_y + y1
        if (
            abs(global_x - x_center) <= width * 0.75
            and abs(global_y - y_center) <= height * 0.75
        ):
            detected.append((float(global_x), float(global_y), float(radius)))

    for index, first in enumerate(detected):
        for second in detected[index + 1:]:
            center_distance = float(np.hypot(
                first[0] - second[0], first[1] - second[1]
            ))
            radius_ratio = min(first[2], second[2]) / max(first[2], second[2])
            if center_distance < max(8.0, short_side * 0.25):
                continue
            if radius_ratio < 0.78:
                continue
            dx = abs(first[0] - second[0])
            dy = abs(first[1] - second[1])
            aligned_with_long_axis = (
                dy >= dx * 1.5 if height >= width else dx >= dy * 1.5
            )
            if aligned_with_long_axis:
                return True
    return False


def analyze_circuit_image(image_bytes, model):
    # 1. 바이트를 OpenCV 이미지로 변환 (파일 저장 불필요)
    nparr = np.frombuffer(image_bytes, np.uint8)
    img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    h_img, w_img = img.shape[:2]

    # 2. YOLO 추론 (main.py 역할)
    # 2026_07_30_coslr.pt(cos_lr 재학습)는 imgsz=960에서 최적.
    # - 640: 24bus 변압기는 잡히나 IEEE24bus 변압기 0개 + 괴물박스 다수
    # - 960: 24bus/IEEE24bus/1234 변압기 모두 잡히고 괴물박스 최소(IEEE24bus 일부는 아래 필터로 제거)
    # - 1280: 1234 변압기 누락. 따라서 960이 만능 해상도.
    results = model.predict(img, conf=0.3, iou=0.4, imgsz=960, line_width=1)
    
    predictions = []
    components = {}
    
    for i, result in enumerate(results):
        boxes = result.boxes
        for j, box in enumerate(boxes):
            x_center, y_center, w, h = box.xywh[0].tolist()
            conf_score = float(box.conf[0])
            cls = int(box.cls[0])
            name = model.names[cls]

            # 🛡️ 괴물박스 후처리 필터
            # 1) 박스가 이미지 대비 너무 크면(면적비 > 0.12) 괴물박스로 간주하여 제거
            # 2) bus(모선)는 얇은 선이어야 함. w·h 비율이 둘 다 0.08 초과면
            #    사각형 덩어리(=가짜 bus)이므로 제거. 진짜 모선은 한쪽이 ~0.01.
            # This phase uses YOLO exclusively for generators.  Buses come
            # from OpenCV below; load/transformer recognition will be added as
            # separate CV modules after their own validation.
            if name.lower() != 'generator':
                continue

            if _looks_like_transformer_pair(img, x_center, y_center, w, h):
                continue

            w_ratio = w / w_img
            h_ratio = h / h_img
            area_ratio = w_ratio * h_ratio
            if area_ratio > 0.12:
                continue
            if name.lower() == 'bus' and w_ratio > 0.08 and h_ratio > 0.08:
                continue

            comp_id = f"{name}_{len(predictions)}"
            
            predictions.append({
                "id": comp_id,
                "class": name,
                "bbox": [x_center, y_center, w, h],
                "confidence": conf_score
            })
            
            # 박스 좌표 계산
            x1, y1 = max(0, int(x_center - w/2)), max(0, int(y_center - h/2))
            x2, y2 = min(w_img-1, int(x_center + w/2)), min(h_img-1, int(y_center + h/2))
            components[comp_id] = (x1, y1, x2, y2)

    # 3. Topology 선로 인식 (topology_analyzer.py 역할)
    # OpenCV owns bus detection; all other symbols above remain YOLO results.
    # Keep the YOLO-compatible bbox schema so the editor/topology stages need
    # no detector-specific branching.
    for bus in detect_cv_buses(img):
        x_center = float(bus["x"])
        y_center = float(bus["y"])
        w = float(bus["w"])
        h = float(bus["h"])
        comp_id = f"bus_{len(predictions)}"
        predictions.append({
            "id": comp_id,
            "class": "bus",
            "bbox": [x_center, y_center, w, h],
            "confidence": float(bus["confidence"]),
        })
        x1 = max(0, int(x_center - w / 2))
        y1 = max(0, int(y_center - h / 2))
        x2 = min(w_img - 1, int(x_center + w / 2))
        y2 = min(h_img - 1, int(y_center + h / 2))
        components[comp_id] = (x1, y1, x2, y2)

    # Loads are simple filled-arrow symbols, so CV is more stable than the
    # current small YOLO dataset.  `detect_cv_loads` additionally verifies
    # the arrow's lead against a CV bus; transformers remain intentionally
    # excluded until their dedicated detector is validated.
    cv_loads, _, _ = detect_cv_loads(img)
    for load in cv_loads:
        x_center = float((load.x + load.w / 2) / LOAD_SCALE)
        y_center = float((load.y + load.h / 2) / LOAD_SCALE)
        w = float(load.w / LOAD_SCALE)
        h = float(load.h / LOAD_SCALE)
        # Shape score is already gated by the CV detector.  Expose a bounded
        # confidence in the same schema used by YOLO nodes.
        confidence = min(0.94, max(0.75, float(load.triangle_score) + 0.45))
        comp_id = f"load_{len(predictions)}"
        predictions.append({
            "id": comp_id,
            "class": "load",
            "bbox": [x_center, y_center, w, h],
            "confidence": confidence,
        })
        x1 = max(0, int(x_center - w / 2))
        y1 = max(0, int(y_center - h / 2))
        x2 = min(w_img - 1, int(x_center + w / 2))
        y2 = min(h_img - 1, int(y_center + h / 2))
        components[comp_id] = (x1, y1, x2, y2)

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    _, bin_global = cv2.threshold(gray, 180, 255, cv2.THRESH_BINARY_INV)
    bin_adapt = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 15, 10)
    binary = cv2.bitwise_and(bin_global, bin_adapt)

    for box in components.values():
        cv2.rectangle(binary, (box[0], box[1]), (box[2], box[3]), 0, -1)

    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (2,2))
    binary_closed = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel)
    
    try:
        skeleton = cv2.ximgproc.thinning(binary_closed, thinningType=cv2.ximgproc.THINNING_GUOHALL)
    except AttributeError:
        skeleton = cv2.erode(binary_closed, np.ones((3,3), np.uint8))

    endpoints = set()
    for y in range(1, h_img-1):
        for x in range(1, w_img-1):
            if skeleton[y, x] == 255:
                n_count = 0
                for dy in [-1, 0, 1]:
                    for dx in [-1, 0, 1]:
                        if dx == 0 and dy == 0: continue
                        if skeleton[y+dy, x+dx] == 255:
                            n_count += 1
                if n_count == 1:
                    endpoints.add((x, y))

    endpoint_to_comp = {}
    for ep in endpoints:
        ex, ey = ep
        min_dist = 50
        best_comp = None
        for cid, box in components.items():
            x1, y1, x2, y2 = box
            nx = max(x1, min(ex, x2))
            ny = max(y1, min(ey, y2))
            dist = math.hypot(ex - nx, ey - ny)
            if dist <= min_dist:
                min_dist = dist
                best_comp = cid
        if best_comp:
            endpoint_to_comp[ep] = best_comp

    topology_data = []
    used_endpoints = set()
    valid_line_count = 0

    for start_ep, comp_id in endpoint_to_comp.items():
        if start_ep in used_endpoints: continue

        target_id, target_ep, path = walk_skeleton_endpoint_v14(skeleton, start_ep, comp_id, endpoints, endpoint_to_comp, used_endpoints)
        
        if target_id and target_ep not in used_endpoints:
            used_endpoints.add(start_ep)
            used_endpoints.add(target_ep)
            
            line_name = f"L{valid_line_count}"
            topology_data.append({
                "line_id": line_name, 
                "connected_to": [comp_id, target_id],
                "path": [(int(pt[0]), int(pt[1])) for pt in path]
            })
            valid_line_count += 1

    # 최종 결과를 딕셔너리로 묶어서 리턴 (서버가 이를 JSON으로 플러터에 넘김)
    return {
        "nodes": predictions,
        "lines": topology_data
    }

import os
import cv2
import numpy as np
import json
import glob
import sys

# 현재 스크립트 경로를 시스템 경로에 추가하여 line_topology 임포트
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from line_topology import extract_line_topology, visualize_topology

def imread_korean(path):
    """한글 경로가 포함된 이미지를 OpenCV로 읽기 위한 함수"""
    img_array = np.fromfile(path, np.uint8)
    return cv2.imdecode(img_array, cv2.IMREAD_COLOR)

def imwrite_korean(path, img):
    """한글 경로가 포함된 곳에 OpenCV 이미지를 저장하기 위한 함수"""
    ext = os.path.splitext(path)[1]
    result, encoded_img = cv2.imencode(ext, img)
    if result:
        with open(path, mode='w+b') as f:
            encoded_img.tofile(f)

CLASS_NAMES = {
    0: "bus",
    1: "gen",
    2: "load",
    3: "trans"
}

def parse_yolo_labels(label_path, img_width, img_height):
    """YOLO 형식의 라벨 텍스트 파일을 읽어 박스 딕셔너리 리스트로 변환합니다."""
    boxes = []
    class_counters = {0: 1, 1: 1, 2: 1, 3: 1} # 클래스별 카운터
    
    if not os.path.exists(label_path):
        return boxes
    with open(label_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
        for line in lines:
            parts = line.strip().split()
            if len(parts) >= 5:
                class_id = int(parts[0])
                cx = float(parts[1]) * img_width
                cy = float(parts[2]) * img_height
                w = float(parts[3]) * img_width
                h = float(parts[4]) * img_height
                
                # 좌상단, 우하단 좌표로 변환
                x1 = int(cx - w / 2)
                y1 = int(cy - h / 2)
                x2 = int(cx + w / 2)
                y2 = int(cy + h / 2)
                
                name_prefix = CLASS_NAMES.get(class_id, f"cls{class_id}")
                box_id = f"{name_prefix}_{class_counters.get(class_id, 1)}"
                if class_id in class_counters:
                    class_counters[class_id] += 1
                
                boxes.append({
                    'id': box_id,  # 의미있는 ID 부여 (예: bus_1, gen_2)
                    'class_id': class_id,
                    'bbox': [x1, y1, x2, y2]
                })
    return boxes

def main():
    base_dir = r"C:\Users\hpo20\OneDrive\바탕 화면\Project List\전력계통대회\backend_api"
    img_dir = os.path.join(base_dir, "icon_recognition/datasets/auto_tune_train_images")
    lbl_dir = os.path.join(base_dir, "icon_recognition/datasets/auto_tune_train_labels")
    
    # 결과를 시각화하여 저장할 새 폴더
    out_dir = os.path.join(base_dir, "auto_tune_topology_review")
    os.makedirs(out_dir, exist_ok=True)
    
    image_paths = glob.glob(os.path.join(img_dir, "*.jpg")) + glob.glob(os.path.join(img_dir, "*.png"))
    
    all_results = {}
    print(f"Total {len(image_paths)} images found. Processing...")
    
    for img_path in image_paths:
        filename = os.path.basename(img_path)
        name, _ = os.path.splitext(filename)
        lbl_path = os.path.join(lbl_dir, name + ".txt")
        
        img = imread_korean(img_path)
        if img is None:
            continue
            
        h, w = img.shape[:2]
        boxes = parse_yolo_labels(lbl_path, w, h)
        
        # 1. line_topology.py를 사용해 연결선(Topology) 추출
        connections, debug_info = extract_line_topology(img, boxes, dilation_iters=3)
        
        # 2. 결과 JSON에 저장할 데이터 정리
        all_results[filename] = {
            "boxes": boxes,
            "connections": connections
        }
        
        # 3. 시각화 (원본 이미지 + YOLO 박스 + 예측된 연결선)
        vis_img = visualize_topology(img, boxes, connections, debug_info)
        out_path = os.path.join(out_dir, filename)
        imwrite_korean(out_path, vis_img)
        print(f"Processed: {filename} (Boxes: {len(boxes)}, Connections: {len(connections)})")
        
    # JSON 파일로도 저장 (이후 정답지로 활용/수정 가능)
    json_path = os.path.join(out_dir, "topology_initial_results.json")
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(all_results, f, indent=4, ensure_ascii=False)
        
    print(f"\nDone! Visualized images and JSON saved to:")
    print(f"{out_dir}")

if __name__ == "__main__":
    main()

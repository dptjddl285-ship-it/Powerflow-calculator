import os
import sys
import glob
import json
import cv2
import numpy as np

# 프로젝트 루트 및 logic 경로 설정
curr_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.abspath(os.path.join(curr_dir, "../../.."))
if project_root not in sys.path:
    sys.path.insert(0, project_root)

from backend_api.line_recognition.logic.generate_topology_samples import parse_yolo_labels, imread_korean, imwrite_korean
from backend_api.line_recognition.logic.port_aware_topology import extract_port_aware_topology
from backend_api.line_recognition.logic.line_topology import CLASS_COLORS, find_empty_space


def visualize_port_aware_topology(image, components, lines, debug_info=None):
    """
    기존 topology_review_results와 동일한 3-패널 형식(원본 + 중앙 트레이싱/라벨 + 우측 텍스트) 시각화
    """
    height, width, _ = image.shape
    
    # 텍스트 마진 및 캔버스 설정
    margin_width = 480
    needed_height = 100 + len(lines) * 28
    canvas_height = max(height, needed_height)
    
    total_width = width * 2 + margin_width
    vis_img = np.ones((canvas_height, total_width, 3), dtype=np.uint8) * 255
    
    # 1. 좌측 원본 이미지
    vis_img[0:height, 0:width] = image.copy()
    
    # 2. 중앙 트레이싱 이미지
    offset_x = width
    vis_img[0:height, offset_x:offset_x+width] = image.copy()
    
    # 빈 공간 탐색용 마스크
    binary_mask = np.zeros((height, width), dtype=np.uint8)
    for comp in components:
        cx, cy, bw, bh = comp['bbox']
        bx1 = int(cx - bw / 2)
        by1 = int(cy - bh / 2)
        bx2 = int(cx + bw / 2)
        by2 = int(cy + bh / 2)
        cv2.rectangle(binary_mask, (max(0, bx1-10), max(0, by1-10)), (min(width, bx2+10), min(height, by2+10)), 255, -1)
        
    # 2-1. 선(Lines) 트레이싱 및 라벨 표시
    for index, line in enumerate(lines):
        line_id = line.get("line_id", f"L{index+1}")
        path = line.get("path", [])
        
        # 고유 색상 생성 (시드 기반)
        np.random.seed((index + 1) * 31415)
        line_color = (int(np.random.randint(20, 200)), int(np.random.randint(20, 200)), int(np.random.randint(20, 200)))
        line["_color"] = line_color
        
        if len(path) >= 2:
            pts = np.array(path, dtype=np.int32).reshape((-1, 1, 2))
            pts_shifted = pts.copy()
            pts_shifted[:, 0, 0] += offset_x
            cv2.polylines(vis_img, [pts_shifted], isClosed=False, color=line_color, thickness=2, lineType=cv2.LINE_AA)
            
            # 중간 지점에 라벨 및 지시선 표시
            mid_idx = len(path) // 2
            mid_x, mid_y = path[mid_idx]
            
            text_label = f"[{line_id}]"
            (tw, th), _ = cv2.getTextSize(text_label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 2)
            
            best_x, best_y = find_empty_space(binary_mask, mid_x, mid_y, tw, th, max_radius=120)
            cv2.rectangle(binary_mask, (max(0, best_x-5), max(0, best_y-th-5)), (min(width, best_x+tw+5), min(height, best_y+5)), 255, -1)
            
            draw_x = best_x + offset_x
            draw_y = best_y
            
            cv2.line(vis_img, (mid_x + offset_x, mid_y), (draw_x + tw//2, draw_y - th//2), (180, 180, 180), 1)
            cv2.putText(vis_img, text_label, (draw_x, draw_y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 4)
            cv2.putText(vis_img, text_label, (draw_x, draw_y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, line_color, 2)

    # 2-2. 컴포넌트 박스 그리기
    for comp in components:
        comp_id = comp['id']
        comp_cls = comp.get('class', 'default')
        color = CLASS_COLORS.get(comp_cls, CLASS_COLORS.get("default", (0, 255, 255)))
        
        cx, cy, bw, bh = comp['bbox']
        x1 = int(cx - bw / 2)
        y1 = int(cy - bh / 2)
        x2 = int(cx + bw / 2)
        y2 = int(cy + bh / 2)
        
        tx1, tx2 = x1 + offset_x, x2 + offset_x
        cv2.rectangle(vis_img, (tx1, y1), (tx2, y2), color, 2)
        
        box_id_str = str(comp_id)
        (tw, th), _ = cv2.getTextSize(box_id_str, cv2.FONT_HERSHEY_SIMPLEX, 0.55, 2)
        
        best_x, best_y = find_empty_space(binary_mask, int(cx), int(cy), tw, th, max_radius=120)
        cv2.rectangle(binary_mask, (max(0, best_x-5), max(0, best_y-th-5)), (min(width, best_x+tw+5), min(height, best_y+5)), 255, -1)
        
        draw_x = best_x + offset_x
        draw_y = best_y
        
        cv2.line(vis_img, (int(cx) + offset_x, int(cy)), (draw_x + tw//2, draw_y - th//2), (180, 180, 180), 1)
        cv2.putText(vis_img, box_id_str, (draw_x, draw_y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 4)
        cv2.putText(vis_img, box_id_str, (draw_x, draw_y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 2)

    # 3. 우측 마진에 텍스트 목록 작성
    text_offset_x = width * 2
    y_offset = 40
    cv2.putText(vis_img, "Port-Aware Line Connections:", (text_offset_x + 20, y_offset), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 0), 2)
    cv2.putText(vis_img, "(Line color matches text color)", (text_offset_x + 20, y_offset + 25), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (100, 100, 100), 1)
    y_offset += 60
    
    for line in lines:
        line_id = line.get("line_id", "L")
        conn_boxes = line.get("connected_to", [])
        line_color = line.get("_color", (0, 0, 0))
        src_port = line.get("source_port", "")
        tgt_port = line.get("target_port", "")
        
        box_text = " <--> ".join(conn_boxes)
        port_info = f" ({src_port}->{tgt_port})" if src_port or tgt_port else ""
        text = f"[{line_id}] : {box_text}{port_info}"
        
        cv2.putText(vis_img, text, (text_offset_x + 20, y_offset), cv2.FONT_HERSHEY_SIMPLEX, 0.55, line_color, 2)
        y_offset += 26
        
    return vis_img


def main():
    line_rec_dir = os.path.abspath(os.path.join(curr_dir, ".."))
    img_dir = os.path.join(line_rec_dir, "datasets", "auto_tune_train_images")
    lbl_dir = os.path.join(line_rec_dir, "datasets", "auto_tune_train_labels")
    
    out_dir = os.path.join(line_rec_dir, "port_aware_review_results")
    os.makedirs(out_dir, exist_ok=True)
    
    image_paths = glob.glob(os.path.join(img_dir, "*.jpg")) + glob.glob(os.path.join(img_dir, "*.png"))
    
    all_results = {}
    print(f"Total {len(image_paths)} images found. Processing with Port-Aware Topology Extractor...")
    
    for img_path in sorted(image_paths):
        filename = os.path.basename(img_path)
        name, _ = os.path.splitext(filename)
        lbl_path = os.path.join(lbl_dir, name + ".txt")
        
        img = imread_korean(img_path)
        if img is None:
            continue
            
        h, w = img.shape[:2]
        raw_boxes = parse_yolo_labels(lbl_path, w, h)
        
        # 포트 인식 입력 형식 변환
        components = []
        for b in raw_boxes:
            x1, y1, x2, y2 = b['bbox']
            cx = float((x1 + x2) / 2.0)
            cy = float((y1 + y2) / 2.0)
            bw = float(x2 - x1)
            bh = float(y2 - y1)
            cls_name = b['id'].split('_')[0]
            components.append({
                "id": b['id'],
                "class": cls_name,
                "bbox": [cx, cy, bw, bh]
            })
            
        # 1. port_aware_topology.py 실행
        lines, debug_info = extract_port_aware_topology(img, components)
        
        # 2. 결과 JSON 데이터 구성
        lines_detail = {}
        connections = []
        for l in lines:
            lid = l.get("line_id")
            conn = l.get("connected_to", [])
            lines_detail[lid] = {
                "connected_to": conn,
                "source_port": l.get("source_port"),
                "target_port": l.get("target_port"),
                "path_length": len(l.get("path", []))
            }
            if conn and conn not in connections:
                connections.append(conn)
                
        all_results[filename] = {
            "boxes_count": len(components),
            "lines_count": len(lines),
            "boxes": raw_boxes,
            "connections": connections,
            "lines_detail": lines_detail
        }
        
        # 3. 시각화 (원본 + 중앙 트레이싱 + 우측 텍스트)
        vis_img = visualize_port_aware_topology(img, components, lines, debug_info)
        out_path = os.path.join(out_dir, filename)
        imwrite_korean(out_path, vis_img)
        print(f"Processed: {filename} (Boxes: {len(components)}, Lines: {len(lines)}, Connections: {len(connections)})")
        
    # JSON 파일 저장
    json_path = os.path.join(out_dir, "topology_results.json")
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(all_results, f, indent=4, ensure_ascii=False)
        
    print(f"\n[DONE] Visualized images and JSON saved to:")
    print(f"{out_dir}")


if __name__ == "__main__":
    main()

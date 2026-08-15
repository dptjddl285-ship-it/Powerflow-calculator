import cv2
import numpy as np

# 클래스별 박스 색상 정의 (BGR 포맷)
CLASS_COLORS = {
    "bus": (0, 0, 255),       # 빨간색
    "gen": (255, 0, 0),       # 파란색
    "load": (0, 200, 0),      # 초록색
    "trans": (200, 0, 200),   # 보라색
    "default": (0, 255, 255)  # 노란색
}

def remove_image_borders(binary):
    """이미지 가장자리의 외곽 테두리(박스) 노이즈를 제거합니다."""
    # 상하좌우 5픽셀 제거
    border_thickness = 5
    binary[0:border_thickness, :] = 0
    binary[-border_thickness:, :] = 0
    binary[:, 0:border_thickness] = 0
    binary[:, -border_thickness:] = 0
    
    return binary

def find_empty_space(binary_mask, start_x, start_y, tw, th, max_radius=150):
    height, width = binary_mask.shape
    best_x, best_y = start_x, start_y
    min_overlap = float('inf')
    
    step = 10
    for r in range(0, max_radius, step):
        angles = range(0, 360, 30) if r > 0 else [0]
        for angle in angles:
            rad = np.deg2rad(angle)
            cx = int(start_x + r * np.cos(rad))
            cy = int(start_y + r * np.sin(rad))
            
            x1 = cx
            y1 = cy - th
            x2 = cx + tw
            y2 = cy + 5
            
            if x1 < 0 or y1 < 0 or x2 >= width or y2 >= height:
                continue
                
            roi = binary_mask[y1:y2, x1:x2]
            overlap = np.count_nonzero(roi)
            
            if overlap == 0:
                return cx, cy
                
            if overlap < min_overlap:
                min_overlap = overlap
                best_x, best_y = cx, cy
                
    return best_x, best_y

def extract_line_topology(image, boxes, dilation_iters=10):
    """
    YOLO 박스 정보와 이미지를 입력받아, OpenCV를 통해 검은색 선을 추적하고
    박스들 간의 연결 관계(Topology)를 추출하는 일반화된 모듈.
    """
    if image is None or not boxes:
        return [], None

    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    
    # 선명한 검은선 추출을 위해 고정 임계값과 OTSU 혼합 사용
    _, binary = cv2.threshold(gray, 200, 255, cv2.THRESH_BINARY_INV)
    
    # 외곽선(액자 형태 테두리) 노이즈 완벽 제거 (test_image5 gen1-gen2 오탐 원인)
    binary = remove_image_borders(binary)
    
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
    binary_morph = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel)

    height, width = binary_morph.shape
    symbol_mask = np.zeros((height, width), dtype=np.uint8)
    
    # 박스를 지울 때 실제 YOLO 박스보다 조금 더 크게 지워서, 
    # 박스 경계선에 걸친 교차점이나 모서리가 확실히 끊어지게 만듦 (1선 2아이콘 원칙 강제)
    expand_margin = 8
    
    for box in boxes:
        x1, y1, x2, y2 = map(int, box['bbox'])
        x1, y1 = max(0, x1 - expand_margin), max(0, y1 - expand_margin)
        x2, y2 = min(width, x2 + expand_margin), min(height, y2 + expand_margin)
        cv2.rectangle(symbol_mask, (x1, y1), (x2, y2), 255, -1)
        
    lines_only = cv2.bitwise_and(binary_morph, cv2.bitwise_not(symbol_mask))
    
    num_labels, labels, stats, centroids = cv2.connectedComponentsWithStats(lines_only, connectivity=8)
    
    box_to_lines = {box['id']: set() for box in boxes}
    dilate_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
    
    # The caller selects the connection tolerance.  Keeping this argument
    # effective permits a bounded, image-only topology ablation.
    
    for box in boxes:
        box_id = box['id']
        x1, y1, x2, y2 = map(int, box['bbox'])
        x1, y1 = max(0, x1), max(0, y1)
        x2, y2 = min(width, x2), min(height, y2)
        
        single_box_mask = np.zeros((height, width), dtype=np.uint8)
        cv2.rectangle(single_box_mask, (x1, y1), (x2, y2), 255, -1)
        
        # 선과 박스가 약간 떨어져 있어도(누락 방지) 잘 이어지도록 팽창 횟수(dilation_iters) 증가
        dilated_box = cv2.dilate(single_box_mask, dilate_kernel, iterations=dilation_iters)
        overlap_region = cv2.bitwise_and(dilated_box, cv2.bitwise_not(single_box_mask))
        
        overlapping_labels = np.unique(labels[overlap_region == 255])
        
        for lbl in overlapping_labels:
            if lbl > 0:
                box_to_lines[box_id].add(lbl)
                
    connections = set()
    
    # 선(Line) 중심으로 어떤 박스들이 연결되어 있는지 매핑
    line_to_boxes = {}
    for box_id, line_labels in box_to_lines.items():
        for lbl in line_labels:
            if lbl not in line_to_boxes:
                line_to_boxes[lbl] = set()
            line_to_boxes[lbl].add(box_id)
            
    # 최소 2개 이상의 박스를 연결하는 유효한 선만 추출하여 Line 번호 부여
    valid_lines = {}
    line_counter = 1
    for lbl, connected_boxes in line_to_boxes.items():
        if len(connected_boxes) > 1:
            line_name = f"Line_{line_counter}"
            valid_lines[line_name] = {
                'label_id': lbl,
                'connected_boxes': sorted(list(connected_boxes))
            }
            line_counter += 1
            
            boxes_list = list(connected_boxes)
            for i in range(len(boxes_list)):
                for j in range(i + 1, len(boxes_list)):
                    connections.add(tuple(sorted([boxes_list[i], boxes_list[j]])))

    debug_info = {
        'labels': labels,
        'valid_lines': valid_lines,
        # Keep raw wire contacts as well as inter-object connections.  A
        # terminal Load may legitimately attach to a dangling wire segment.
        'box_to_lines': box_to_lines,
        'binary': binary_morph
    }
                
    return list(connections), debug_info

def visualize_topology(image, boxes, connections, debug_info=None):
    """
    디버깅용 시각화 함수. 박스와 실제 추적된 검은선을 그리고, 우측 텍스트와 좌측에 원본 이미지를 함께 띄움.
    """
    height, width, _ = image.shape
    
    valid_lines = debug_info['valid_lines'] if debug_info else {}
    labels = debug_info['labels'] if debug_info else None
    binary_mask = debug_info['binary'].copy() if debug_info and 'binary' in debug_info else np.zeros((height, width), dtype=np.uint8)
    
    # 박스 영역을 마스크에 추가 (텍스트가 박스 위로 올라가지 않도록 방어)
    for box in boxes:
        bx1, by1, bx2, by2 = map(int, box['bbox'])
        cv2.rectangle(binary_mask, (max(0, bx1-10), max(0, by1-10)), (min(width, bx2+10), min(height, by2+10)), 255, -1)
    
    margin_width = 450
    needed_height = 100 + len(valid_lines) * 25
    canvas_height = max(height, needed_height)
    
    # [좌측: 원본] + [중앙: 트레이싱] + [우측: 텍스트 마진]
    total_width = width * 2 + margin_width
    vis_img = np.ones((canvas_height, total_width, 3), dtype=np.uint8) * 255
    
    # 좌측에 원본 배치
    vis_img[0:height, 0:width] = image.copy()
    
    # 중앙에 트레이싱 이미지 배치
    offset_x = width
    vis_img[0:height, offset_x:offset_x+width] = image.copy()
    
    # 1. 선 그리기 및 회로도 상단에 선 번호 표시 (중앙 이미지에만)
    if labels is not None:
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
        
        for line_name, info in valid_lines.items():
            lbl = info['label_id']
            np.random.seed(lbl * 123)
            line_color = (int(np.random.randint(0, 180)), int(np.random.randint(0, 180)), int(np.random.randint(0, 180)))
            
            line_mask = np.zeros_like(labels, dtype=np.uint8)
            line_mask[labels == lbl] = 255
            dilated_line_mask = cv2.dilate(line_mask, kernel, iterations=1)
            
            vis_img[0:height, offset_x:offset_x+width][dilated_line_mask == 255] = line_color
            
            y_coords, x_coords = np.where(line_mask == 255)
            if len(y_coords) > 0:
                center_y = int(np.median(y_coords))
                center_x = int(np.median(x_coords))
                
                text_label = f"[{line_name}]"
                (tw, th), _ = cv2.getTextSize(text_label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 2)
                
                # 빈 공간 탐색
                best_x, best_y = find_empty_space(binary_mask, center_x, center_y, tw, th, max_radius=150)
                # 점유 영역 마스킹
                cv2.rectangle(binary_mask, (max(0, best_x-5), max(0, best_y-th-5)), (min(width, best_x+tw+5), min(height, best_y+5)), 255, -1)
                
                draw_x = best_x + offset_x
                draw_y = best_y
                
                # 지시선 그리기
                cv2.line(vis_img, (center_x + offset_x, center_y), (draw_x + tw//2, draw_y - th//2), (180, 180, 180), 1)
                
                cv2.putText(vis_img, text_label, (draw_x, draw_y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 4)
                cv2.putText(vis_img, text_label, (draw_x, draw_y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, line_color, 2)

    # 2. 박스 그리기 (중앙 이미지에만)
    for box in boxes:
        box_id = box['id']
        class_name = box_id.split('_')[0]
        color = CLASS_COLORS.get(class_name, CLASS_COLORS["default"])
        
        x1, y1, x2, y2 = map(int, box['bbox'])
        tx1, tx2 = x1 + offset_x, x2 + offset_x
        cv2.rectangle(vis_img, (tx1, y1), (tx2, y2), color, 2)
        
        box_id_str = str(box_id)
        (tw, th), _ = cv2.getTextSize(box_id_str, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
        
        orig_cx = (x1 + x2) // 2
        orig_cy = (y1 + y2) // 2
        
        best_x, best_y = find_empty_space(binary_mask, orig_cx, orig_cy, tw, th, max_radius=150)
        cv2.rectangle(binary_mask, (max(0, best_x-5), max(0, best_y-th-5)), (min(width, best_x+tw+5), min(height, best_y+5)), 255, -1)
        
        draw_x = best_x + offset_x
        draw_y = best_y
        
        cv2.line(vis_img, (orig_cx + offset_x, orig_cy), (draw_x + tw//2, draw_y - th//2), (180, 180, 180), 1)
        
        cv2.putText(vis_img, box_id_str, (draw_x, draw_y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 4)
        cv2.putText(vis_img, box_id_str, (draw_x, draw_y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)
        
    # 3. 우측 마진에 텍스트 목록 작성
    text_offset_x = width * 2
    if debug_info is not None:
        y_offset = 40
        cv2.putText(vis_img, "Line Connections:", (text_offset_x + 20, y_offset), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 2)
        cv2.putText(vis_img, "(Line color matches text color)", (text_offset_x + 20, y_offset + 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (100, 100, 100), 1)
        y_offset += 60
        
        for line_name, info in valid_lines.items():
            lbl = info['label_id']
            conn_boxes = info['connected_boxes']
            
            np.random.seed(lbl * 123)
            line_color = (int(np.random.randint(0, 180)), int(np.random.randint(0, 180)), int(np.random.randint(0, 180)))
            
            box_text = " <--> ".join(conn_boxes)
            text = f"[{line_name}] : {box_text}"
            
            cv2.putText(vis_img, text, (text_offset_x + 20, y_offset), cv2.FONT_HERSHEY_SIMPLEX, 0.6, line_color, 2)
            y_offset += 25
            
    return vis_img

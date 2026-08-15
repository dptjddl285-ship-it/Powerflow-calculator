import cv2
import numpy as np

def recover_missing_loads(image, existing_boxes, min_area=50, max_area=3000):
    """
    API Documentation:
    recover_missing_loads(image, existing_boxes, min_area, max_area)
    
    Accepts:
        image: BGR numpy array of the circuit diagram.
        existing_boxes: list of dicts, each with 'bbox' [x1, y1, x2, y2] and 'id'.
    
    Returns:
        list of dicts representing recovered Load boxes, in the same format.
        
    Limitations:
        - Geometric Dependency: Relies heavily on morphological opening. If lines are thicker than the kernel, they may be misclassified as blobs.
        - Precision: May falsely detect text characters (like 'A' or 'V') if they are triangular, highly solid, and touch a line.
        - Conservative: Might miss highly stylized or hollow loads that fail solidity checks.
    """
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(gray, 200, 255, cv2.THRESH_BINARY_INV)
    
    # Mask out existing YOLO boxes
    mask = np.ones_like(binary) * 255
    for box in existing_boxes:
        x1, y1, x2, y2 = map(int, box['bbox'])
        exp = 5
        cv2.rectangle(mask, (max(0, x1-exp), max(0, y1-exp)), 
                            (min(binary.shape[1], x2+exp), min(binary.shape[0], y2+exp)), 0, -1)
        
    search_space = cv2.bitwise_and(binary, mask)
    
    # Separate thick blobs (potential icons) from thin lines using a slightly larger kernel
    blob_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (7, 7))
    blobs = cv2.morphologyEx(search_space, cv2.MORPH_OPEN, blob_kernel)
    
    contours, _ = cv2.findContours(blobs, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    lines_only = cv2.bitwise_and(search_space, cv2.bitwise_not(blobs))
    
    recovered_boxes = []
    load_count = 1
    
    for cnt in contours:
        area = cv2.contourArea(cnt)
        if area < 80 or area > max_area:  # Increased min_area to avoid small noise/text
            continue
            
        peri = cv2.arcLength(cnt, True)
        approx = cv2.approxPolyDP(cnt, 0.05 * peri, True)
        
        # Triangle or Arrow (3 to 7 vertices)
        if 3 <= len(approx) <= 7:
            hull = cv2.convexHull(cnt)
            hull_area = cv2.contourArea(hull)
            if hull_area == 0:
                continue
                
            solidity = float(area) / hull_area
            # Extremely strict solidity for filled compact shapes (rejects text like A, V)
            if solidity > 0.85:
                x, y, w, h = cv2.boundingRect(cnt)
                aspect_ratio = float(w) / h
                
                # Loads are relatively symmetric, reject long rectangular blobs
                if 0.5 <= aspect_ratio <= 2.0:
                    
                    # Exactly ONE external line attachment check
                    # 1. Create a local mask for the candidate
                    exp = 6
                    roi_x1, roi_y1 = max(0, x - exp), max(0, y - exp)
                    roi_x2, roi_y2 = min(search_space.shape[1], x + w + exp), min(search_space.shape[0], y + h + exp)
                    
                    if roi_x2 <= roi_x1 or roi_y2 <= roi_y1:
                        continue
                        
                    local_cnt_mask = np.zeros((roi_y2 - roi_y1, roi_x2 - roi_x1), dtype=np.uint8)
                    # Shift contour to local ROI coordinates
                    local_cnt = cnt - [roi_x1, roi_y1]
                    cv2.drawContours(local_cnt_mask, [local_cnt], -1, 255, -1)
                    
                    # 2. Dilate to create a ring around the candidate
                    dilate_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
                    dilated_mask = cv2.dilate(local_cnt_mask, dilate_kernel, iterations=1)
                    ring = cv2.bitwise_and(dilated_mask, cv2.bitwise_not(local_cnt_mask))
                    
                    # 3. Intersect the ring with the lines image
                    local_lines = lines_only[roi_y1:roi_y2, roi_x1:roi_x2]
                    touching_lines = cv2.bitwise_and(ring, local_lines)
                    
                    # 4. Count connected components in the touching lines
                    num_labels, _, _, _ = cv2.connectedComponentsWithStats(touching_lines, connectivity=8)
                    
                    # num_labels includes background (0). So exactly 1 line attachment means num_labels == 2.
                    if num_labels == 2:
                        recovered_boxes.append({
                            'id': f'recovered_load_{load_count}',
                            'bbox': [x, y, x + w, y + h]
                        })
                        load_count += 1
                        
    return recovered_boxes

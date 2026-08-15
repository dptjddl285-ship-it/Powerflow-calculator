import os
import glob
import cv2
import json
import sys
import numpy as np

# Append parent dir to path so we can import core modules
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from ultralytics import YOLO
from core.vision_logic import analyze_circuit_image

def run_validation():
    test_img_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'test_images'))
    output_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), 'output'))
    model_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'models', '2026_07_30_coslr.pt'))
    
    os.makedirs(output_dir, exist_ok=True)
    
    if not os.path.exists(model_path):
        model_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'models', 'best.pt'))
        
    print(f"Loading YOLO model from: {model_path}")
    model = YOLO(model_path)
    
    image_files = glob.glob(os.path.join(test_img_dir, '*.jpg'))
    if not image_files:
        print("No images found in test_images folder.")
        return
        
    print(f"Found {len(image_files)} images. Starting full validation with Side-by-Side view...")
    
    stats = {
        'total_images': len(image_files),
        'bus_count': 0, 'gen_count': 0, 'load_count': 0, 'trans_count': 0
    }
    
    colors = {
        'generator': (0, 0, 255),    # Red
        'bus': (255, 0, 0),          # Blue
        'load': (0, 255, 0),         # Green
        'transformer': (0, 255, 255) # Yellow
    }
    
    for i, img_path in enumerate(image_files):
        img_name = os.path.basename(img_path)
        with open(img_path, 'rb') as f:
            image_bytes = f.read()
            
        img_bgr = cv2.imread(img_path)
        if img_bgr is None: continue
        
        img_original = img_bgr.copy()
        
        try:
            result = analyze_circuit_image(image_bytes, model, filename=img_name)
            nodes = result.get('nodes', [])
        except Exception as e:
            print(f"Error on {img_name}: {e}")
            nodes = []
            
        local_counts = {'bus': 0, 'generator': 0, 'load': 0, 'transformer': 0}
            
        for node in nodes:
            cls_name = node['class'].lower()
            x_c, y_c, w, h = node['bbox']
            x1, y1 = int(x_c - w/2), int(y_c - h/2)
            x2, y2 = int(x_c + w/2), int(y_c + h/2)
            
            color = colors.get(cls_name, (255, 255, 255))
            cv2.rectangle(img_bgr, (x1, y1), (x2, y2), color, 2)
            cv2.putText(img_bgr, cls_name, (x1, max(0, y1 - 5)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)
            
            if 'bus' in cls_name: 
                stats['bus_count'] += 1; local_counts['bus'] += 1
            elif 'gen' in cls_name: 
                stats['gen_count'] += 1; local_counts['generator'] += 1
            elif 'load' in cls_name: 
                stats['load_count'] += 1; local_counts['load'] += 1
            elif 'trans' in cls_name: 
                stats['trans_count'] += 1; local_counts['transformer'] += 1
        
        # Heuristic Judgment
        is_valid = (local_counts['bus'] > 0)
        judgment_text = "Judgment: " + ("GOOD (Bus Detected)" if is_valid else "REVIEW NEEDED (No Bus)")
        judgment_color = (0, 255, 0) if is_valid else (0, 0, 255)
        
        # Create Side-by-Side Image
        h, w = img_original.shape[:2]
        target_h = max(h, 600) # Ensure it's tall enough for text
        
        canvas = np.zeros((target_h, w * 2, 3), dtype=np.uint8)
        canvas.fill(255) # White background
        
        canvas[0:h, 0:w] = img_original
        canvas[0:h, w:w*2] = img_bgr
        
        # Add labels and stats
        cv2.putText(canvas, f"Original: {img_name}", (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 0, 0), 2)
        cv2.putText(canvas, "Detected Output", (w + 10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 0, 0), 2)
        
        info_text = f"Found -> Bus: {local_counts['bus']}, Gen: {local_counts['generator']}, Load: {local_counts['load']}, Trans: {local_counts['transformer']}"
        cv2.putText(canvas, info_text, (w + 10, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 0, 0), 2)
        cv2.putText(canvas, judgment_text, (w + 10, 110), cv2.FONT_HERSHEY_SIMPLEX, 0.8, judgment_color, 2)
        
        out_path = os.path.join(output_dir, img_name)
        cv2.imwrite(out_path, canvas)
        
        if (i+1) % 10 == 0:
            print(f"Processed {i+1}/{len(image_files)} images...")
            
    print("\n" + "="*40)
    print("FULL VALIDATION SUMMARY")
    print(f"Total Images Processed: {stats['total_images']}")
    print(f"Buses Detected: {stats['bus_count']}")
    print(f"Generators Detected: {stats['gen_count']}")
    print(f"Loads Detected: {stats['load_count']}")
    print(f"Transformers Detected: {stats['trans_count']}")
    print("="*40)

if __name__ == '__main__':
    run_validation()

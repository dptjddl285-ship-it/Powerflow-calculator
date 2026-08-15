import cv2
import os

img_dir = "icon_recognition/datasets/auto_tune_test_images"
lbl_dir = "icon_recognition/datasets/auto_tune_test_labels"
out_dir = "test_label_check"

os.makedirs(out_dir, exist_ok=True)

class_names = {
    0: "bus",
    1: "generator",
    2: "load",
    3: "transformer"
}

colors = {
    0: (255, 0, 0),    # Blue for bus
    1: (0, 255, 0),    # Green for generator
    2: (0, 0, 255),    # Red for load
    3: (0, 255, 255)   # Yellow for transformer
}

def parse_yolo_label(line, img_w, img_h):
    parts = line.strip().split()
    if len(parts) < 5:
        return None
    class_id = int(parts[0])
    x_center = float(parts[1])
    y_center = float(parts[2])
    w = float(parts[3])
    h = float(parts[4])
    
    x1 = int((x_center - w/2) * img_w)
    y1 = int((y_center - h/2) * img_h)
    x2 = int((x_center + w/2) * img_w)
    y2 = int((y_center + h/2) * img_h)
    
    return class_id, x1, y1, x2, y2

for filename in os.listdir(img_dir):
    if filename.endswith(".jpg"):
        img_path = os.path.join(img_dir, filename)
        lbl_path = os.path.join(lbl_dir, filename.replace(".jpg", ".txt"))
        
        img = cv2.imread(img_path)
        if img is None:
            continue
            
        img_h, img_w = img.shape[:2]
        
        if os.path.exists(lbl_path):
            with open(lbl_path, 'r') as f:
                lines = f.readlines()
                for line in lines:
                    parsed = parse_yolo_label(line, img_w, img_h)
                    if parsed is not None:
                        class_id, x1, y1, x2, y2 = parsed
                        color = colors.get(class_id, (255, 255, 255))
                        name = class_names.get(class_id, "unknown")
                        
                        cv2.rectangle(img, (x1, y1), (x2, y2), color, 2)
                        cv2.putText(img, name, (x1, max(y1 - 5, 10)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 2)
                        
        out_path = os.path.join(out_dir, filename)
        cv2.imwrite(out_path, img)
        print(f"Processed and saved: {filename}")

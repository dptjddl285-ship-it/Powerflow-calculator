import sys, os
sys.path.insert(0, os.path.abspath('.'))
import cv2
import numpy as np
from pathlib import Path
from backend_api.line_recognition.logic.vision_logic_topology_hybrid import (
    MODEL, CLASS_MAP, _letterbox_to_reference, _has_direct_wire_contact,
    _looks_like_numeric_text, has_distinct_load_bypass_shape
)

targets = [
    ("KakaoTalk_20260815_154947878_06.jpg", "Image 06: Bus 17, loads at bus 4, 7, 13"),
    ("KakaoTalk_20260815_154947878_08.jpg", "Image 08: Digit 4 as load, duplicate transformer"),
    ("KakaoTalk_20260815_154947878_13.jpg", "Image 13: Missing generator"),
    ("KakaoTalk_20260815_154956634_03.jpg", "Image 03: Digit 7 as load"),
    ("KakaoTalk_20260815_154956634_05.jpg", "Image 05: Missing downward load"),
]

for filename, desc in targets:
    img_path = Path("new pictures") / filename
    if not img_path.exists():
        continue
    img = cv2.imread(str(img_path))
    h, w = img.shape[:2]
    ref_rgb, scale, ox, oy = _letterbox_to_reference(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    ref_bgr = cv2.cvtColor(ref_rgb, cv2.COLOR_RGB2BGR)
    
    # Run raw prediction at low threshold (0.05)
    res = MODEL.predict(ref_rgb, conf=0.03, iou=0.4, max_det=300, imgsz=1280, verbose=False)[0]
    
    print(f"\n==========================================")
    print(f" {filename} ({desc}) [Size: {w}x{h}]")
    print(f"==========================================")
    for b in res.boxes:
        cname = CLASS_MAP[int(b.cls[0])]
        conf = float(b.conf[0])
        rx1, ry1, rx2, ry2 = b.xyxy[0].tolist()
        rcx, rcy, rw, rh = (rx1+rx2)/2.0, (ry1+ry2)/2.0, rx2-rx1, ry2-ry1
        
        # map to original coords
        ox1 = max(0, int((rx1 - ox) / scale))
        oy1 = max(0, int((ry1 - oy) / scale))
        ox2 = min(w, int((rx2 - ox) / scale))
        oy2 = min(h, int((ry2 - oy) / scale))
        
        # checks
        is_num = _looks_like_numeric_text(ref_bgr, [rcx, rcy, rw, rh])
        has_wire = _has_direct_wire_contact(ref_bgr, [rcx, rcy, rw, rh])
        has_shape = has_distinct_load_bypass_shape(img, [(ox1+ox2)/2, (oy1+oy2)/2, ox2-ox1, oy2-oy1])
        
        # filter printing for relevant classes or regions
        print(f"  {cname:11} conf={conf:.3f} orig_box=[{ox1},{oy1},{ox2},{oy2}] size={ox2-ox1}x{oy2-oy1} | num_text={is_num} wire_contact={has_wire} load_shape={has_shape}")

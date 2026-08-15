"""Build a dedicated, clean comparison gallery folder structure.

Folder structure:
feedback_artifacts/antigravity_independent_loop/comparison_gallery/
  ├── original/          (Copied original raw pictures)
  ├── boxed/             (Newly predicted boxed detection images)
  ├── side_by_side/      (Clean merged images: Left = ORIGINAL, Right = NEW DETECTION)
  ├── index.html         (Interactive visual viewer)
  └── COMPARISON_INDEX.md (Markdown catalog)
"""

import cv2
import shutil
import numpy as np
from pathlib import Path

PROJECT_ROOT = Path("C:/Users/hpo20/orca/workspaces/Powerflow-calculator/antigravity-independent-feedback-loop")
RAW_DIR = PROJECT_ROOT / "new pictures"
BASE_OUT = PROJECT_ROOT / "feedback_artifacts" / "antigravity_independent_loop" / "comparison_gallery"

ORIGINAL_DIR = BASE_OUT / "original"
BOXED_DIR = BASE_OUT / "boxed"
SBS_DIR = BASE_OUT / "side_by_side"

for d in [ORIGINAL_DIR, BOXED_DIR, SBS_DIR]:
    d.mkdir(parents=True, exist_ok=True)

# Copy boxed images from benchmark output
SRC_BOXED_DIR = PROJECT_ROOT / "feedback_artifacts" / "antigravity_independent_loop" / "new_pictures"

raw_images = sorted(RAW_DIR.glob("*.jpg"))

def create_labeled_side_by_side(orig_img, boxed_img, title_left="ORIGINAL (RAW)", title_right="NEW DETECTION (BOXED)"):
    h1, w1 = orig_img.shape[:2]
    h2, w2 = boxed_img.shape[:2]
    target_h = max(h1, h2)
    
    # Resize with aspect ratio preserved to target height
    scale1 = target_h / h1
    scale2 = target_h / h2
    new_w1 = int(round(w1 * scale1))
    new_w2 = int(round(w2 * scale2))
    
    resized_orig = cv2.resize(orig_img, (new_w1, target_h), interpolation=cv2.INTER_AREA)
    resized_boxed = cv2.resize(boxed_img, (new_w2, target_h), interpolation=cv2.INTER_AREA)
    
    # Add top banner
    banner_h = 44
    gap = 12
    total_w = new_w1 + gap + new_w2
    total_h = target_h + banner_h
    
    canvas = np.full((total_h, total_w, 3), 24, dtype=np.uint8) # Dark background
    
    # Paste images
    canvas[banner_h:total_h, 0:new_w1] = resized_orig
    canvas[banner_h:total_h, new_w1 + gap:total_w] = resized_boxed
    
    # Draw banners
    # Left banner (Blue)
    cv2.rectangle(canvas, (0, 0), (new_w1, banner_h), (30, 41, 59), -1)
    cv2.putText(canvas, title_left, (16, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (56, 189, 248), 2, cv2.LINE_AA)
    
    # Right banner (Green)
    cv2.rectangle(canvas, (new_w1 + gap, 0), (total_w, banner_h), (30, 41, 59), -1)
    cv2.putText(canvas, title_right, (new_w1 + gap + 16, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (74, 222, 128), 2, cv2.LINE_AA)
    
    # Center separator line
    cv2.line(canvas, (new_w1 + gap // 2, 0), (new_w1 + gap // 2, total_h), (71, 85, 105), 2)
    
    return canvas

print(f"Processing {len(raw_images)} images into clean comparison gallery...")

for idx, img_path in enumerate(raw_images, 1):
    stem = img_path.stem
    # 1. Copy raw original
    dst_orig = ORIGINAL_DIR / img_path.name
    shutil.copy2(img_path, dst_orig)
    
    # 2. Copy predicted boxed
    src_boxed = SRC_BOXED_DIR / f"{stem}_boxed.jpg"
    dst_boxed = BOXED_DIR / f"{stem}_boxed.jpg"
    if src_boxed.exists():
        shutil.copy2(src_boxed, dst_boxed)
    
    # 3. Create labeled Side-by-Side
    if src_boxed.exists():
        orig_mat = cv2.imread(str(img_path))
        boxed_mat = cv2.imread(str(src_boxed))
        sbs = create_labeled_side_by_side(orig_mat, boxed_mat, f"ORIGINAL #{idx:02d} ({img_path.name})", f"NEW DETECTION #{idx:02d} (BOXED)")
        dst_sbs = SBS_DIR / f"{stem}_comparison.jpg"
        cv2.imwrite(str(dst_sbs), sbs, [cv2.IMWRITE_JPEG_QUALITY, 95])

print("Comparison gallery created successfully at:", BASE_OUT)

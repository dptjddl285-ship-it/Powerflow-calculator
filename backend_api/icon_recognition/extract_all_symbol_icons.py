import os, sys, cv2, json
import numpy as np
from pathlib import Path
from collections import defaultdict

CLASS_NAMES = {0: "bus", 1: "generator", 2: "load", 3: "transformer"}

train_img_dir = Path("backend_api/icon_recognition/datasets/auto_tune_train_images")
train_lbl_dir = Path("backend_api/icon_recognition/datasets/auto_tune_train_labels")

test_img_dir = Path("backend_api/icon_recognition/datasets/auto_tune_test_images")
test_lbl_dir = Path("backend_api/icon_recognition/datasets/auto_tune_test_labels")

out_dir = Path("backend_api/icon_recognition/extracted_symbols")
for cname in CLASS_NAMES.values():
    (out_dir / cname).mkdir(parents=True, exist_ok=True)

artifacts_dir = Path("feedback_artifacts/antigravity_independent_loop")
artifacts_dir.mkdir(parents=True, exist_ok=True)

extracted_icons = defaultdict(list)

def process_dataset(img_dir, lbl_dir, split_name):
    for img_path in sorted(img_dir.glob("*.jpg")):
        lbl_path = lbl_dir / f"{img_path.stem}.txt"
        if not lbl_path.exists():
            continue
            
        img = cv2.imread(str(img_path))
        if img is None:
            continue
        h, w = img.shape[:2]
        
        with open(lbl_path, "r", encoding="utf-8") as f:
            for line_idx, line in enumerate(f):
                parts = line.strip().split()
                if len(parts) < 5:
                    continue
                cls_id = int(parts[0])
                cx, cy, bw, bh = map(float, parts[1:5])
                
                cname = CLASS_NAMES.get(cls_id, "unknown")
                
                # Convert normalized YOLO bbox to pixel coords
                px_cx = cx * w
                px_cy = cy * h
                px_w = bw * w
                px_h = bh * h
                
                pad = 4
                x1 = max(0, int(round(px_cx - px_w / 2.0)) - pad)
                y1 = max(0, int(round(px_cy - px_h / 2.0)) - pad)
                x2 = min(w, int(round(px_cx + px_w / 2.0)) + pad)
                y2 = min(h, int(round(px_cy + px_h / 2.0)) + pad)
                
                if x2 <= x1 or y2 <= y1:
                    continue
                    
                crop = img[y1:y2, x1:x2]
                icon_filename = f"{split_name}_{img_path.stem}_cls{cls_id}_{line_idx}_{cname}.png"
                icon_path = out_dir / cname / icon_filename
                cv2.imwrite(str(icon_path), crop)
                
                extracted_icons[cname].append({
                    "file": icon_filename,
                    "path": str(icon_path),
                    "crop": crop,
                    "w": px_w,
                    "h": px_h,
                    "aspect": px_w / max(1.0, px_h)
                })

print("Extracting symbols from train dataset...")
process_dataset(train_img_dir, train_lbl_dir, "train")

if test_img_dir.exists() and test_lbl_dir.exists():
    print("Extracting symbols from test dataset...")
    process_dataset(test_img_dir, test_lbl_dir, "test")

print("\nExtraction Summary:")
for cname, icons in extracted_icons.items():
    print(f" - {cname}: {len(icons)} distinct instances extracted")

# Build a Master Visual Catalog Image
# Show up to 12 sample icons per category in a nice grid
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

fig, axes = plt.subplots(4, 8, figsize=(16, 9), dpi=200)
fig.suptitle("⚡ Powerflow Master Symbol Catalog (Extracted from Datasets)", fontsize=16, fontweight='bold', y=0.98)

categories = ["bus", "generator", "load", "transformer"]
cat_titles = [
    "1. Bus (모선 - 수평/수직 실선 바)",
    "2. Generator (발전기 - 원형/물결/G/Slack)",
    "3. Load (부하 - 하향/상향/좌우 삼각 화살표)",
    "4. Transformer (변압기 - 코일형/2원형 교차)"
]

for row_idx, (cname, title) in enumerate(zip(categories, cat_titles)):
    icons = extracted_icons[cname]
    # Sample 8 diverse icons
    if len(icons) >= 8:
        step = max(1, len(icons) // 8)
        samples = [icons[i * step] for i in range(8)]
    else:
        samples = icons[:8]
        
    for col_idx in range(8):
        ax = axes[row_idx, col_idx]
        if col_idx < len(samples):
            crop_bgr = samples[col_idx]["crop"]
            crop_rgb = cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2RGB)
            ax.imshow(crop_rgb)
            ax.set_title(f"{samples[col_idx]['w']:.0f}x{samples[col_idx]['h']:.0f}px", fontsize=8)
        ax.axis('off')
    
    axes[row_idx, 0].text(-0.3, 0.5, title, transform=axes[row_idx, 0].transAxes,
                           fontsize=11, fontweight='bold', va='center', ha='right', rotation=0)

plt.tight_layout(rect=[0.22, 0.02, 0.98, 0.94])
catalog_img_path = artifacts_dir / "master_symbol_catalog.png"
fig.savefig(catalog_img_path, bbox_inches='tight')
plt.close(fig)

print(f"\nSaved Master Symbol Catalog Image to: {catalog_img_path}")

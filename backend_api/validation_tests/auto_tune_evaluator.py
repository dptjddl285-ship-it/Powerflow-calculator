"""Leakage-safe evaluator for the auto-tune detector.

It evaluates predictions against labels only after the detector has produced
them.  The detector receives image bytes and never receives a filename or a
label path, so it cannot use file-specific exceptions or ground-truth boxes.
"""

import argparse
import importlib
import json
import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from collections import defaultdict
from pathlib import Path

import cv2


PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


CLASS_MAP = {0: "bus", 1: "generator", 2: "load", 3: "transformer"}


def iou(a, b):
    ax1, ay1 = a[0] - a[2] / 2, a[1] - a[3] / 2
    ax2, ay2 = a[0] + a[2] / 2, a[1] + a[3] / 2
    bx1, by1 = b[0] - b[2] / 2, b[1] - b[3] / 2
    bx2, by2 = b[0] + b[2] / 2, b[1] + b[3] / 2
    ix1, iy1, ix2, iy2 = max(ax1, bx1), max(ay1, by1), min(ax2, bx2), min(ay2, by2)
    intersection = max(0, ix2 - ix1) * max(0, iy2 - iy1)
    union = a[2] * a[3] + b[2] * b[3] - intersection
    return intersection / union if union else 0.0


def labels_for(path, width, height):
    labels = []
    for line in path.read_text(encoding="utf-8").splitlines():
        values = line.split()
        if len(values) < 5:
            continue
        class_id, coords = int(values[0]), [float(value) for value in values[1:]]
        if len(coords) == 4:
            x, y, w, h = coords
        else:
            xs, ys = coords[::2], coords[1::2]
            x, y, w, h = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, max(xs) - min(xs), max(ys) - min(ys)
        labels.append({"class": CLASS_MAP[class_id], "bbox": [x * width, y * height, w * width, h * height]})
    return labels


def draw_alignment_overlay(image_path, truth, prediction, output_path):
    image = cv2.imread(str(image_path))
    for item in truth:
        x, y, w, h = map(int, item["bbox"])
        cv2.rectangle(image, (x - w // 2, y - h // 2), (x + w // 2, y + h // 2), (0, 180, 0), 2)
        cv2.putText(image, f"GT:{item['class']}", (x - w // 2, y - h // 2 - 3), cv2.FONT_HERSHEY_SIMPLEX, .35, (0, 180, 0), 1)
    for item in prediction:
        x, y, w, h = map(int, item["bbox"])
        cv2.rectangle(image, (x - w // 2, y - h // 2), (x + w // 2, y + h // 2), (0, 0, 230), 2)
        cv2.putText(image, f"PRED:{item['class']}", (x - w // 2, y + h // 2 + 12), cv2.FONT_HERSHEY_SIMPLEX, .35, (0, 0, 230), 1)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(output_path), image)


def evaluate(split, module_name, iou_threshold, diagnostic_dir=None):
    root = Path(__file__).resolve().parents[1] / "icon_recognition" / "datasets"
    image_dir, label_dir = root / f"auto_tune_{split}_images", root / f"auto_tune_{split}_labels"
    analyzer = getattr(importlib.import_module(module_name), module_name.rsplit(".", 1)[-1].replace("vision_logic_", "analyze_circuit_image_"))
    totals, per_class, failures = defaultdict(int), {name: defaultdict(int) for name in CLASS_MAP.values()}, []
    for image_path in sorted(image_dir.glob("*.jpg")):
        image = cv2.imread(str(image_path))
        height, width = image.shape[:2]
        truth = labels_for(label_dir / f"{image_path.stem}.txt", width, height)
        # Do not pass filename: detector must be independent from file identity.
        prediction = analyzer(image_path.read_bytes()).get("nodes", [])
        used = set()
        image_counts = defaultdict(int)
        for detected in prediction:
            candidates = [(iou(detected["bbox"], target["bbox"]), idx) for idx, target in enumerate(truth)
                          if target["class"] == detected["class"] and idx not in used]
            best_iou, best_index = max(candidates, default=(0.0, None))
            if best_iou >= iou_threshold:
                used.add(best_index)
                totals["tp"] += 1
                per_class[detected["class"]]["tp"] += 1
                image_counts["tp"] += 1
            else:
                totals["fp"] += 1
                per_class[detected["class"]]["fp"] += 1
                image_counts["fp"] += 1
        missed = len(truth) - len(used)
        totals["fn"] += missed
        for index, target in enumerate(truth):
            if index not in used:
                per_class[target["class"]]["fn"] += 1
        image_counts["fn"] += missed
        if image_counts["fp"] or missed:
            failures.append({"image": image_path.name, **image_counts, "predictions": len(prediction), "targets": len(truth)})
        if diagnostic_dir and image_counts["tp"] == 0 and len(truth) >= 2 and len(prediction) >= 2:
            draw_alignment_overlay(image_path, truth, prediction, diagnostic_dir / f"{image_path.stem}_alignment.png")
    denom = 2 * totals["tp"] + totals["fp"] + totals["fn"]
    score = 100.0 * (2 * totals["tp"] / denom if denom else 0.0)
    class_metrics = {}
    for name, counts in per_class.items():
        tp, fp, fn = counts["tp"], counts["fp"], counts["fn"]
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        class_metrics[name] = {"tp": tp, "fp": fp, "fn": fn, "targets": tp + fn,
                               "detected_correctly": tp, "precision": precision, "recall": recall,
                               "f1": 2 * precision * recall / (precision + recall) if precision + recall else 0.0}
    report = {"split": split, "module": module_name, "iou_threshold": iou_threshold, "score": score,
              "exact_100": totals["fp"] == 0 and totals["fn"] == 0, "totals": dict(totals), "failures": failures}
    report["per_class"] = class_metrics
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", choices=("train", "test"), required=True)
    parser.add_argument("--module", default="backend_api.line_recognition.logic.vision_logic_topology_hybrid")
    parser.add_argument("--iou", type=float, default=0.4)
    parser.add_argument("--diagnostic-dir", type=Path)
    args = parser.parse_args()
    evaluate(args.split, args.module, args.iou, args.diagnostic_dir)

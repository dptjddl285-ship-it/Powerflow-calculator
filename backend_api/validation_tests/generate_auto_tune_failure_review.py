"""Create human-reviewable Train failure overlays without affecting inference.

Green boxes are ground truth, magenta boxes are false positives, and yellow
boxes are missed ground-truth objects.  The detector only receives image bytes;
labels are read here after inference solely for evaluation and visualization.
"""

import argparse
import importlib
import sys
from pathlib import Path

import cv2

from backend_api.validation_tests.auto_tune_evaluator import iou, labels_for


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


def rectangle(image, bbox, color, text, thickness=3):
    x, y, width, height = map(int, bbox)
    x1, y1, x2, y2 = x - width // 2, y - height // 2, x + width // 2, y + height // 2
    cv2.rectangle(image, (x1, y1), (x2, y2), color, thickness)
    cv2.putText(image, text, (x1, max(20, y1 - 8)), cv2.FONT_HERSHEY_SIMPLEX, .7, color, 2, cv2.LINE_AA)
    return x1, y1, x2, y2


def review(split, module_name, output_dir, iou_threshold=.4):
    root = Path(__file__).resolve().parents[1] / "icon_recognition" / "datasets"
    image_dir, label_dir = root / f"auto_tune_{split}_images", root / f"auto_tune_{split}_labels"
    analyzer_name = module_name.rsplit(".", 1)[-1].replace("vision_logic_", "analyze_circuit_image_")
    analyzer = getattr(importlib.import_module(module_name), analyzer_name)
    output_dir.mkdir(parents=True, exist_ok=True)

    for image_path in sorted(image_dir.glob("*.jpg")):
        image = cv2.imread(str(image_path))
        height, width = image.shape[:2]
        truth = labels_for(label_dir / f"{image_path.stem}.txt", width, height)
        predictions = analyzer(image_path.read_bytes()).get("nodes", [])
        used, false_positives = set(), []
        for prediction in predictions:
            candidates = [(iou(prediction["bbox"], target["bbox"]), index) for index, target in enumerate(truth)
                          if target["class"] == prediction["class"] and index not in used]
            score, index = max(candidates, default=(0.0, None))
            if score >= iou_threshold:
                used.add(index)
            else:
                false_positives.append(prediction)
        missed = [target for index, target in enumerate(truth) if index not in used]
        if not false_positives and not missed:
            continue

        annotated = image.copy()
        for target in truth:
            rectangle(annotated, target["bbox"], (0, 180, 0), f"GT {target['class']}", 1)
        error_boxes = []
        for index, prediction in enumerate(false_positives, start=1):
            error_boxes.append(rectangle(annotated, prediction["bbox"], (255, 0, 255), f"FP {index}: {prediction['class']}", 4))
        for index, target in enumerate(missed, start=1):
            error_boxes.append(rectangle(annotated, target["bbox"], (0, 220, 255), f"FN {index}: {target['class']}", 4))
        cv2.imwrite(str(output_dir / f"{image_path.stem}_errors.png"), annotated)

        for index, (x1, y1, x2, y2) in enumerate(error_boxes, start=1):
            padding = max(100, (x2 - x1) * 4, (y2 - y1) * 4)
            crop = annotated[max(0, y1 - padding):min(height, y2 + padding), max(0, x1 - padding):min(width, x2 + padding)]
            cv2.imwrite(str(output_dir / f"{image_path.stem}_error_{index}_zoom.png"), crop)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", choices=("train", "test"), default="train")
    parser.add_argument("--module", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--iou", type=float, default=.4)
    args = parser.parse_args()
    review(args.split, args.module, args.output_dir, args.iou)

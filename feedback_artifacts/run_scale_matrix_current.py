"""One-shot, leakage-safe scale-robustness diagnostic.

The detector receives only encoded image bytes.  Labels are read separately
for scoring and normalized coordinates remain valid for the synthetic resize
variants because every source image is 1280x1280.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

import cv2

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend_api.validation_tests.auto_tune_evaluator import iou, labels_for


IMAGE_DIR = ROOT / "backend_api" / "icon_recognition" / "datasets" / "auto_tune_train_images"
LABEL_DIR = ROOT / "backend_api" / "icon_recognition" / "datasets" / "auto_tune_train_labels"
MODULE_NAME = "backend_api.line_recognition.logic.vision_logic_topology_hybrid"
ANALYZER_NAME = "analyze_circuit_image_topology_hybrid"
VARIANTS = ((640, 640), (912, 900), (1280, 720), (1600, 900), (900, 1400))
EXCLUDED = {"test_image35.jpg"}
CLASS_NAMES = ("bus", "generator", "load", "transformer")


def score_variant(analyzer, width: int, height: int) -> dict:
    totals = defaultdict(int)
    per_class = {name: defaultdict(int) for name in CLASS_NAMES}
    failures = []
    for image_path in sorted(IMAGE_DIR.glob("*.jpg")):
        if image_path.name in EXCLUDED:
            continue
        image = cv2.imread(str(image_path))
        source_height, source_width = image.shape[:2]
        variant = cv2.resize(image, (width, height), interpolation=cv2.INTER_AREA)
        ok, encoded = cv2.imencode(".jpg", variant)
        if not ok:
            raise RuntimeError(f"could not encode {image_path.name}")
        truth = labels_for(
            LABEL_DIR / f"{image_path.stem}.txt", source_width, source_height
        )
        # The synthetic variants are deliberately resized in pixel space, so
        # convert the absolute source boxes into the variant coordinate system
        # before scoring (normalized YOLO labels themselves remain unchanged).
        sx, sy = width / source_width, height / source_height
        for target in truth:
            target["bbox"][0] *= sx
            target["bbox"][1] *= sy
            target["bbox"][2] *= sx
            target["bbox"][3] *= sy
        prediction = analyzer(encoded.tobytes()).get("nodes", [])
        used = set()
        image_counts = defaultdict(int)
        for detected in prediction:
            candidates = [
                (iou(detected["bbox"], target["bbox"]), index)
                for index, target in enumerate(truth)
                if target["class"] == detected["class"] and index not in used
            ]
            best_iou, best_index = max(candidates, default=(0.0, None))
            if best_iou >= 0.4:
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
        if image_counts["fp"] or image_counts["fn"]:
            failures.append({"image": image_path.name, **image_counts})

    denominator = 2 * totals["tp"] + totals["fp"] + totals["fn"]
    score = 100.0 * (2 * totals["tp"] / denominator if denominator else 0.0)
    return {
        "size": [width, height],
        "images": len(list(IMAGE_DIR.glob("*.jpg"))) - len(EXCLUDED),
        "score": score,
        "totals": dict(totals),
        "per_class": {name: dict(values) for name, values in per_class.items()},
        "failures": failures,
    }


def main() -> None:
    os.environ.setdefault(
        "AUTO_TUNE_MODEL_PATH",
        "runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt",
    )
    os.environ.setdefault("AUTO_TUNE_USE_PORT_AWARE", "1")
    os.environ.setdefault("AUTO_TUNE_USE_CV_LOAD_PORTS", "1")
    os.environ.setdefault("AUTO_TUNE_USE_SECONDARY_INFERENCE", "1")
    os.environ.setdefault("AUTO_TUNE_USE_CV_BUS_RESCUES", "1")
    module = importlib.import_module(MODULE_NAME)
    analyzer = getattr(module, ANALYZER_NAME)
    report = []
    for width, height in VARIANTS:
        print(f"running {width}x{height}", flush=True)
        result = score_variant(analyzer, width, height)
        report.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    output = ROOT / "feedback_artifacts" / "scale_matrix_current.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved {output}")


if __name__ == "__main__":
    main()

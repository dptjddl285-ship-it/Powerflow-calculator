"""Train the offline image-only Load-vs-text crop classifier from Train data."""

import argparse
import importlib
import os
from pathlib import Path

import cv2
import joblib
import numpy as np
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC

from backend_api.line_recognition.logic.load_text_filter import MODEL_PATH, hog_feature
from backend_api.validation_tests.auto_tune_evaluator import iou, labels_for


ROOT = Path(__file__).resolve().parents[1] / "icon_recognition" / "datasets"


def rectangle_iou(first, second):
    ax, ay, aw, ah = first
    bx, by, bw, bh = second
    intersection = max(0, min(ax + aw, bx + bw) - max(ax, bx)) * max(0, min(ay + ah, by + bh) - max(ay, by))
    union = aw * ah + bw * bh - intersection
    return intersection / union if union else 0.0


def crop_feature(image, bbox):
    center_x, center_y, width, height = map(int, bbox)
    image_height, image_width = image.shape[:2]
    crop = image[max(0, center_y - height // 2):min(image_height, center_y + height // 2),
                 max(0, center_x - width // 2):min(image_width, center_x + width // 2)]
    return hog_feature(cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--module", default="backend_api.line_recognition.logic.vision_logic_topology_hybrid")
    parser.add_argument("--iou", type=float, default=.4)
    args = parser.parse_args()
    analyzer = getattr(importlib.import_module(args.module), "analyze_circuit_image_topology_hybrid")
    features, targets, weights = [], [], []
    summary = {"positive": 0, "hard_negative": 0, "component_negative": 0}

    for image_path in sorted((ROOT / "auto_tune_train_images").glob("*.jpg")):
        image = cv2.imread(str(image_path))
        height, width = image.shape[:2]
        truth = labels_for(ROOT / "auto_tune_train_labels" / f"{image_path.stem}.txt", width, height)
        used = set()
        for node in analyzer(image_path.read_bytes())["nodes"]:
            if node["class"] != "load":
                continue
            candidates = [(iou(node["bbox"], item["bbox"]), index) for index, item in enumerate(truth)
                          if item["class"] == "load" and index not in used]
            overlap, index = max(candidates, default=(0.0, None))
            features.append(crop_feature(image, node["bbox"]))
            if overlap >= args.iou:
                used.add(index)
                targets.append(1)
                weights.append(1.0)
                summary["positive"] += 1
            else:
                # A detector-produced false Load is a particularly informative
                # negative, so it is weighted without encoding its identity.
                targets.append(0)
                weights.append(10.0)
                summary["hard_negative"] += 1

        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        count, _, stats, _ = cv2.connectedComponentsWithStats((gray < 180).astype("uint8"), 8)
        known_boxes = [(item["bbox"][0] - item["bbox"][2] / 2, item["bbox"][1] - item["bbox"][3] / 2,
                        item["bbox"][2], item["bbox"][3]) for item in truth]
        for x, y, box_width, box_height, area in stats[1:count]:
            if not (12 <= box_width <= 40 and 12 <= box_height <= 40 and .45 <= box_width / box_height <= 2.2 and 25 <= area <= 600):
                continue
            if any(rectangle_iou((x, y, box_width, box_height), known) > .05 for known in known_boxes):
                continue
            features.append(hog_feature(gray[y:y + box_height, x:x + box_width]))
            targets.append(0)
            weights.append(1.0)
            summary["component_negative"] += 1

    classifier = make_pipeline(StandardScaler(), SVC(kernel="rbf", C=2, class_weight="balanced"))
    classifier.fit(features, targets, svc__sample_weight=weights)
    MODEL_PATH.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(classifier, MODEL_PATH)
    print({**summary, "model": str(MODEL_PATH)})


if __name__ == "__main__":
    main()

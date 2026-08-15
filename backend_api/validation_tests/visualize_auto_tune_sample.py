"""Render Train-only ground truth and detector boxes for label-alignment diagnosis."""

import argparse
import os
from pathlib import Path

import cv2

from auto_tune_evaluator import labels_for


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--module", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    import importlib
    module = importlib.import_module(args.module)
    analyzer = getattr(module, args.module.rsplit(".", 1)[-1].replace("vision_logic_", "analyze_circuit_image_"))
    image_path = Path(args.image)
    image = cv2.imread(str(image_path))
    labels = labels_for(image_path.parents[1] / "icon_recognition/datasets/auto_tune_train_labels" / f"{image_path.stem}.txt", image.shape[1], image.shape[0])
    for item in labels:
        x, y, w, h = map(int, item["bbox"])
        cv2.rectangle(image, (x - w // 2, y - h // 2), (x + w // 2, y + h // 2), (0, 180, 0), 2)
        cv2.putText(image, f"GT:{item['class']}", (x - w // 2, y - h // 2 - 3), cv2.FONT_HERSHEY_SIMPLEX, .35, (0, 180, 0), 1)
    for item in analyzer(image_path.read_bytes())["nodes"]:
        x, y, w, h = map(int, item["bbox"])
        cv2.rectangle(image, (x - w // 2, y - h // 2), (x + w // 2, y + h // 2), (0, 0, 230), 2)
        cv2.putText(image, f"YOLO:{item['class']}", (x - w // 2, y + h // 2 + 12), cv2.FONT_HERSHEY_SIMPLEX, .35, (0, 0, 230), 1)
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(args.output, image)


if __name__ == "__main__":
    main()

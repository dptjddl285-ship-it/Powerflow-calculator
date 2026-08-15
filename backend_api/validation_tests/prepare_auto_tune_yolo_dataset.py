"""Build a disposable YOLO training copy without changing source data.

The source annotations legitimately mix boxes and polygons.  Ultralytics
requires one annotation kind per image, so polygon rows are converted to their
enclosing normalized boxes only in the generated training copy.
"""

import argparse
from pathlib import Path
import shutil


ROOT = Path(__file__).resolve().parents[1]
SOURCE_IMAGES = ROOT / "icon_recognition/datasets/auto_tune_train_images"
SOURCE_LABELS = ROOT / "icon_recognition/datasets/auto_tune_train_labels"


def normalize_row(row):
    values = row.split()
    if len(values) == 5:
        return row.strip()
    class_id, coords = values[0], [float(value) for value in values[1:]]
    xs, ys = coords[::2], coords[1::2]
    x, y = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    width, height = max(xs) - min(xs), max(ys) - min(ys)
    return f"{class_id} {x:.8f} {y:.8f} {width:.8f} {height:.8f}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", type=Path, default=ROOT / "auto_tune_yolo" / "train")
    args = parser.parse_args()
    target = args.target if args.target.is_absolute() else ROOT / args.target
    image_target, label_target = target / "images", target / "labels"
    image_target.mkdir(parents=True, exist_ok=True)
    label_target.mkdir(parents=True, exist_ok=True)
    for image in SOURCE_IMAGES.glob("*.jpg"):
        shutil.copy2(image, image_target / image.name)
    for label in SOURCE_LABELS.glob("*.txt"):
        normalized = [normalize_row(row) for row in label.read_text(encoding="utf-8").splitlines() if row.strip()]
        (label_target / label.name).write_text("\n".join(normalized) + "\n", encoding="utf-8")
    print(f"Prepared {len(list(image_target.glob('*.jpg')))} images and {len(list(label_target.glob('*.txt')))} labels.")


if __name__ == "__main__":
    main()

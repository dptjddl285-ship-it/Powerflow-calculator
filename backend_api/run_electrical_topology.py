"""Render production object detection plus electrical-rule line topology."""

from __future__ import annotations

import argparse
from collections import Counter
import csv
import json
import os
from pathlib import Path
import sys

import cv2
import numpy as np


BACKEND = Path(__file__).resolve().parent
ROOT = BACKEND.parent
IMAGE_ROOT = ROOT / "학습 IEEE"
MODEL_PATH = BACKEND / "models" / "2026_07_30_coslr.pt"
DEFAULT_IMAGES = "24bus.jpg,39bus.jpg,TEST1.jpg,TEST2.jpg,TEST3.jpg,TEST4.jpg,TEST5.jpg,TEST6.jpg"

os.environ.setdefault(
    "YOLO_CONFIG_DIR",
    str(ROOT / "_external_compare" / "ultralytics_config"),
)
os.environ.setdefault(
    "MPLCONFIGDIR",
    str(ROOT / "_external_compare" / "matplotlib_config"),
)
os.environ.setdefault("WINDIR", r"C:\Windows")
os.environ.setdefault("SystemRoot", r"C:\Windows")
os.environ["POWERLENS_TOPOLOGY_DEBUG"] = "1"

from ultralytics import YOLO  # noqa: E402

sys.path.insert(0, str(BACKEND))
from core.vision_logic import analyze_circuit_image  # noqa: E402


COLOURS = {
    "bus": (0, 175, 0),
    "generator": (0, 140, 255),
    # Keep loads blue so their boxes remain visually distinct from the
    # red conductor paths rendered below.
    "load": (255, 0, 0),
    "transformer": (210, 0, 210),
}

# OpenCV uses BGR.  Keep the line order stable so L0 is red, L1 orange, ...
# and the sequence repeats after violet.  This is a visual aid for following
# a path through crossings; it does not affect topology selection.
LINE_COLOURS = (
    (0, 0, 255),       # red
    (0, 165, 255),     # orange
    (0, 255, 255),     # yellow
    (0, 128, 0),       # green
    (255, 0, 0),       # blue
    (130, 0, 75),      # indigo
    (238, 130, 238),  # violet
)


def read_image(path: Path) -> np.ndarray:
    image = cv2.imdecode(np.fromfile(str(path), np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise FileNotFoundError(path)
    return image


def save_image(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 95])
    if not ok:
        raise RuntimeError(path)
    encoded.tofile(str(path))


def build_display_id_map(nodes: list[dict]) -> dict[str, str]:
    """Map zero-based internal ids to the one-based detector labels in the image."""
    counters: dict[str, int] = {}
    display_ids: dict[str, str] = {}
    prefixes = {
        "bus": "B",
        "load": "L",
        "generator": "G",
        "transformer": "T",
    }
    for node in nodes:
        class_name = str(node.get("class", "unknown"))
        counters[class_name] = counters.get(class_name, 0) + 1
        prefix = prefixes.get(class_name, class_name[:1].upper() or "N")
        component_id = str(node.get("id", ""))
        if component_id:
            display_ids[component_id] = f"{prefix}{counters[class_name]}"
    return display_ids


def format_component_id(
    component_id: object,
    display_ids: dict[str, str] | None = None,
) -> str:
    """Render the same one-based id that appears beside the detected object."""
    key = str(component_id)
    if display_ids and key in display_ids:
        return display_ids[key]
    return key.replace("_", "")


def format_connection(
    line: dict,
    display_ids: dict[str, str] | None = None,
) -> str:
    endpoints = line.get("connected_to", [])
    return " <-> ".join(
        format_component_id(endpoint, display_ids)
        for endpoint in endpoints
    )


def render(image: np.ndarray, data: dict, title: str) -> np.ndarray:
    canvas = image.copy()
    for line_index, line in enumerate(data.get("lines", [])):
        path = line.get("path", [])
        if len(path) < 2:
            continue
        points = np.asarray(path, dtype=np.int32).reshape(-1, 1, 2)
        line_colour = LINE_COLOURS[line_index % len(LINE_COLOURS)]
        cv2.polylines(canvas, [points], False, line_colour, 2, cv2.LINE_AA)
        midpoint = path[len(path) // 2]
        cv2.putText(
            canvas,
            str(line.get("line_id", "L")),
            (int(midpoint[0]) + 3, int(midpoint[1]) - 4),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.40,
            line_colour,
            1,
            cv2.LINE_AA,
        )

    class_counts: Counter[str] = Counter()
    for node in data.get("nodes", []):
        class_name = str(node.get("class", "unknown"))
        class_counts[class_name] += 1
        x, y, width, height = (float(value) for value in node["bbox"])
        x1, y1 = int(round(x - width / 2)), int(round(y - height / 2))
        x2, y2 = int(round(x + width / 2)), int(round(y + height / 2))
        colour = COLOURS.get(class_name, (80, 80, 80))
        cv2.rectangle(canvas, (x1, y1), (x2, y2), colour, 2)
        cv2.putText(
            canvas,
            f"{class_name[0].upper()}{class_counts[class_name]}",
            (x1, max(14, y1 - 4)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.36,
            colour,
            1,
            cv2.LINE_AA,
        )

    counts = Counter(node["class"] for node in data.get("nodes", []))
    header = np.full((38, canvas.shape[1], 3), 255, np.uint8)
    text = (
        f"{title} | B{counts['bus']} G{counts['generator']} "
        f"L{counts['load']} T{counts['transformer']} | lines {len(data.get('lines', []))}"
    )
    cv2.putText(header, text, (7, 17), cv2.FONT_HERSHEY_SIMPLEX, 0.44, (0, 0, 0), 1, cv2.LINE_AA)
    cv2.putText(header, "line colors: R-O-Y-G-B-I-V repeat, blue box=load", (7, 33), cv2.FONT_HERSHEY_SIMPLEX, 0.32, (70, 70, 70), 1, cv2.LINE_AA)
    return cv2.vconcat([header, canvas])


def make_contact_sheet(items: list[tuple[str, np.ndarray]]) -> np.ndarray:
    columns = 2
    tile_width, tile_height = 540, 520
    rows = (len(items) + columns - 1) // columns
    sheet = np.full((rows * tile_height, columns * tile_width, 3), 255, np.uint8)
    for index, (name, image) in enumerate(items):
        row, column = divmod(index, columns)
        available_height = tile_height - 24
        scale = min(tile_width / image.shape[1], available_height / image.shape[0])
        resized = cv2.resize(
            image,
            (max(1, int(round(image.shape[1] * scale))), max(1, int(round(image.shape[0] * scale)))),
            interpolation=cv2.INTER_AREA,
        )
        x = column * tile_width + (tile_width - resized.shape[1]) // 2
        y = row * tile_height + 24 + (available_height - resized.shape[0]) // 2
        sheet[y:y + resized.shape[0], x:x + resized.shape[1]] = resized
        cv2.putText(sheet, name, (column * tile_width + 5, row * tile_height + 17), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (0, 0, 0), 1, cv2.LINE_AA)
    return sheet


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--images", default=DEFAULT_IMAGES)
    parser.add_argument("--output", default="electrical_topology_latest")
    parser.add_argument(
        "--load-mask-mode",
        choices=("box", "triangle", "core_contour"),
        default="box",
    )
    args = parser.parse_args()
    names = [item.strip() for item in args.images.split(",") if item.strip()]
    output = ROOT / args.output
    output.mkdir(parents=True, exist_ok=True)
    model = YOLO(str(MODEL_PATH))
    rows = []
    contact_items = []

    for position, name in enumerate(names, start=1):
        source = IMAGE_ROOT / name
        image = read_image(source)
        data = analyze_circuit_image(
            source.read_bytes(),
            model,
            load_mask_mode=args.load_mask_mode,
        )
        topology_masks = data.pop("_topology_masks", {})
        display_ids = build_display_id_map(data.get("nodes", []))
        rendered = render(image, data, name)
        folder = output / source.stem
        save_image(folder / "result.jpg", rendered)
        for mask_name, mask in topology_masks.items():
            save_image(folder / f"{mask_name}.jpg", cv2.cvtColor(mask, cv2.COLOR_GRAY2BGR))
        serializable = {
            "nodes": data.get("nodes", []),
            "lines": data.get("lines", []),
            "topology_debug": data.get("topology_debug", {}),
        }
        for line in serializable["lines"]:
            line["connection_label"] = format_connection(line, display_ids)
        (folder / "result.json").write_text(
            json.dumps(serializable, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        connections_text = "\n".join(
            f"{line.get('line_id', 'L')}: {line.get('connection_label', format_connection(line, display_ids))}"
            for line in serializable["lines"]
        )
        (folder / "connections.txt").write_text(
            connections_text + ("\n" if connections_text else ""),
            encoding="utf-8",
        )
        counts = Counter(node["class"] for node in data.get("nodes", []))
        rows.append({
            "image": name,
            "bus": counts["bus"],
            "generator": counts["generator"],
            "load": counts["load"],
            "transformer": counts["transformer"],
            "lines": len(data.get("lines", [])),
        })
        contact_items.append((name, rendered))
        print(
            f"[{position}/{len(names)}] {name}: "
            f"B{counts['bus']} G{counts['generator']} L{counts['load']} "
            f"T{counts['transformer']} lines={len(data.get('lines', []))}",
            flush=True,
        )

    with (output / "summary.csv").open("w", newline="", encoding="utf-8-sig") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    save_image(output / "contact_sheet.jpg", make_contact_sheet(contact_items))


if __name__ == "__main__":
    main()

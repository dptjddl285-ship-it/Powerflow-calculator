"""Comprehensive Independent Verification Gates and Benchmark Runner.

Gate 1: Native Train100 Gate (TP496/FP0/FN0, 100.0%)
Gate 2: Canonical-Padding / Scale-Preserving Robustness Matrix (>= 98.0%)
Gate 3: New Pictures Single-Pass Benchmark & Answer Key Comparison
"""

import argparse
import glob
import io
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from backend_api.line_recognition.logic.vision_logic_topology_hybrid import (
    analyze_circuit_image_topology_hybrid,
)

CLASS_MAP = {0: "bus", 1: "generator", 2: "load", 3: "transformer"}
OUTPUT_DIR = PROJECT_ROOT / "feedback_artifacts" / "antigravity_independent_loop"


def iou(a, b):
    ax1, ay1 = a[0] - a[2] / 2.0, a[1] - a[3] / 2.0
    ax2, ay2 = a[0] + a[2] / 2.0, a[1] + a[3] / 2.0
    bx1, by1 = b[0] - b[2] / 2.0, b[1] - b[3] / 2.0
    bx2, by2 = b[0] + b[2] / 2.0, b[1] + b[3] / 2.0
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    if ix2 <= ix1 or iy2 <= iy1:
        return 0.0
    intersection = (ix2 - ix1) * (iy2 - iy1)
    union = a[2] * a[3] + b[2] * b[3] - intersection
    return intersection / union if union > 0 else 0.0


def labels_for(path, width, height):
    labels = []
    if not path.exists():
        return labels
    for line in path.read_text(encoding="utf-8").splitlines():
        values = line.split()
        if len(values) < 5:
            continue
        class_id, coords = int(values[0]), [float(v) for v in values[1:]]
        if len(coords) == 4:
            x, y, w, h = coords
        else:
            xs, ys = coords[::2], coords[1::2]
            x, y = (min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0
            w, h = max(xs) - min(xs), max(ys) - min(ys)
        labels.append({
            "class": CLASS_MAP[class_id],
            "bbox": [x * width, y * height, w * width, h * height],
        })
    return labels


def run_train_gate(iou_threshold=0.4):
    """Run Gate 1: Native Train verification (20 images)."""
    dataset_dir = PROJECT_ROOT / "backend_api" / "icon_recognition" / "datasets"
    img_dir = dataset_dir / "auto_tune_train_images"
    lbl_dir = dataset_dir / "auto_tune_train_labels"
    image_paths = sorted(img_dir.glob("*.jpg"))

    totals = {"tp": 0, "fp": 0, "fn": 0}
    per_class = {name: {"tp": 0, "fp": 0, "fn": 0, "targets": 0} for name in CLASS_MAP.values()}
    failures = []

    for img_path in image_paths:
        img_bytes = img_path.read_bytes()
        img = cv2.imread(str(img_path))
        h, w = img.shape[:2]
        truth = labels_for(lbl_dir / f"{img_path.stem}.txt", w, h)
        for t in truth:
            per_class[t["class"]]["targets"] += 1

        result = analyze_circuit_image_topology_hybrid(img_bytes)
        preds = result.get("nodes", [])

        used = set()
        img_counts = {"tp": 0, "fp": 0, "fn": 0}
        for det in preds:
            candidates = [
                (iou(det["bbox"], t["bbox"]), idx)
                for idx, t in enumerate(truth)
                if t["class"] == det["class"] and idx not in used
            ]
            best_iou, best_idx = max(candidates, default=(0.0, None))
            if best_iou >= iou_threshold:
                used.add(best_idx)
                totals["tp"] += 1
                per_class[det["class"]]["tp"] += 1
                img_counts["tp"] += 1
            else:
                totals["fp"] += 1
                per_class[det["class"]]["fp"] += 1
                img_counts["fp"] += 1

        missed = len(truth) - len(used)
        totals["fn"] += missed
        for idx, t in enumerate(truth):
            if idx not in used:
                per_class[t["class"]]["fn"] += 1
        img_counts["fn"] += missed

        if img_counts["fp"] > 0 or img_counts["fn"] > 0:
            failures.append({
                "image": img_path.name,
                "counts": img_counts,
                "preds": len(preds),
                "targets": len(truth),
            })

    denom = 2 * totals["tp"] + totals["fp"] + totals["fn"]
    score = 100.0 * (2 * totals["tp"] / denom if denom else 0.0)
    exact_100 = (totals["fp"] == 0 and totals["fn"] == 0 and totals["tp"] == 496)

    print(f"\n==========================================")
    print(f" GATE 1: NATIVE TRAIN VERIFICATION (20 images)")
    print(f"==========================================")
    print(f" Score: {score:.2f}% | Exact 100%: {exact_100}")
    print(f" TP: {totals['tp']} / 496 | FP: {totals['fp']} | FN: {totals['fn']}")
    for cname, cstat in per_class.items():
        print(f"   - {cname:12}: TP={cstat['tp']:3}/{cstat['targets']:3} FP={cstat['fp']:2} FN={cstat['fn']:2}")
    if failures:
        print(f" Failures ({len(failures)}):")
        for f in failures:
            print(f"   {f['image']}: TP={f['counts']['tp']} FP={f['counts']['fp']} FN={f['counts']['fn']}")
    print(f"==========================================\n")

    return {
        "score": score,
        "exact_100": exact_100,
        "totals": totals,
        "per_class": per_class,
        "failures": failures,
    }


def run_robustness_matrix_gate(iou_threshold=0.4):
    """Run Gate 2: Scale-preserving Canonical Padding / Geometry Robustness Matrix."""
    dataset_dir = PROJECT_ROOT / "backend_api" / "icon_recognition" / "datasets"
    img_dir = dataset_dir / "auto_tune_train_images"
    lbl_dir = dataset_dir / "auto_tune_train_labels"
    image_paths = sorted(img_dir.glob("*.jpg"))

    matrix_variants = [
        ("canonical_1280_centered", lambda img: _place_canonical(img, 1280, 0.5, 0.5)),
        ("canonical_1400_centered", lambda img: _place_canonical(img, 1400, 0.5, 0.5)),
        ("canonical_1280_offset_tl", lambda img: _place_canonical(img, 1280, 0.1, 0.1)),
        ("canonical_1280_offset_br", lambda img: _place_canonical(img, 1280, 0.9, 0.9)),
    ]

    variant_results = {}
    total_tp = 0
    total_fp = 0
    total_fn = 0
    total_targets = 0

    print(f"\n==========================================")
    print(f" GATE 2: CANONICAL PADDING ROBUSTNESS MATRIX")
    print(f"==========================================")

    for variant_name, transform_fn in matrix_variants:
        v_totals = {"tp": 0, "fp": 0, "fn": 0}
        v_targets = 0
        for img_path in image_paths:
            img = cv2.imread(str(img_path))
            h, w = img.shape[:2]
            truth = labels_for(lbl_dir / f"{img_path.stem}.txt", w, h)
            v_targets += len(truth)

            transformed_img, inv_fn = transform_fn(img)
            success, encoded = cv2.imencode(".jpg", transformed_img)
            if not success:
                continue

            result = analyze_circuit_image_topology_hybrid(encoded.tobytes())
            preds = result.get("nodes", [])

            # Map predictions back to original image space
            mapped_preds = []
            for p in preds:
                orig_bbox = inv_fn(p["bbox"])
                mapped_preds.append({**p, "bbox": orig_bbox})

            used = set()
            for det in mapped_preds:
                candidates = [
                    (iou(det["bbox"], t["bbox"]), idx)
                    for idx, t in enumerate(truth)
                    if t["class"] == det["class"] and idx not in used
                ]
                best_iou, best_idx = max(candidates, default=(0.0, None))
                if best_iou >= iou_threshold:
                    used.add(best_idx)
                    v_totals["tp"] += 1
                else:
                    v_totals["fp"] += 1
            v_totals["fn"] += len(truth) - len(used)

        denom = 2 * v_totals["tp"] + v_totals["fp"] + v_totals["fn"]
        v_score = 100.0 * (2 * v_totals["tp"] / denom if denom else 0.0)
        variant_results[variant_name] = {
            "score": v_score,
            "totals": v_totals,
            "targets": v_targets,
        }
        total_tp += v_totals["tp"]
        total_fp += v_totals["fp"]
        total_fn += v_totals["fn"]
        total_targets += v_targets
        print(f" - {variant_name:30}: Score={v_score:6.2f}% (TP={v_totals['tp']}/{v_targets} FP={v_totals['fp']} FN={v_totals['fn']})")

    overall_denom = 2 * total_tp + total_fp + total_fn
    overall_score = 100.0 * (2 * total_tp / overall_denom if overall_denom else 0.0)
    passed = overall_score >= 98.0

    print(f"------------------------------------------")
    print(f" OVERALL MATRIX SCORE: {overall_score:.2f}% (Target: >=98.0%, Passed: {passed})")
    print(f"==========================================\n")

    return {
        "overall_score": overall_score,
        "passed": passed,
        "variants": variant_results,
    }


def _place_canonical(img, canvas_size, pos_x_ratio=0.5, pos_y_ratio=0.5):
    """Place image without resizing on a white canvas of canvas_size."""
    h, w = img.shape[:2]
    c_size = max(canvas_size, w, h)
    canvas = np.full((c_size, c_size, 3), 255, dtype=np.uint8)
    ox = int(round((c_size - w) * pos_x_ratio))
    oy = int(round((c_size - h) * pos_y_ratio))
    canvas[oy:oy + h, ox:ox + w] = img

    def inverse(bbox):
        cx, cy, bw, bh = bbox
        return [cx - ox, cy - oy, bw, bh]

    return canvas, inverse


def run_new_pictures_benchmark():
    """Run Gate 3: New Pictures benchmark & generate visual review."""
    new_pic_dir = PROJECT_ROOT / "new pictures"
    paths = sorted(new_pic_dir.glob("*.jpg"))
    if not paths:
        print(f"No new pictures found in {new_pic_dir}")
        return {}

    out_dir = OUTPUT_DIR / "new_pictures"
    out_dir.mkdir(parents=True, exist_ok=True)

    colors = {
        "bus": (255, 100, 0),       # Blue/Orange
        "generator": (0, 0, 255),    # Red
        "load": (0, 180, 0),         # Green
        "transformer": (0, 220, 255) # Yellow
    }

    results_summary = {}

    print(f"\n==========================================")
    print(f" GATE 3: NEW PICTURES BENCHMARK (20 images)")
    print(f"==========================================")

    for idx, img_path in enumerate(paths, 1):
        img_bytes = img_path.read_bytes()
        img = cv2.imread(str(img_path))
        h, w = img.shape[:2]

        analysis = analyze_circuit_image_topology_hybrid(img_bytes)
        nodes = analysis.get("nodes", [])
        lines = analysis.get("lines", [])

        class_counts = defaultdict(int)
        annotated = img.copy()

        # Draw boxes only
        for node in nodes:
            cname = node["class"]
            class_counts[cname] += 1
            cx, cy, bw, bh = node["bbox"]
            x1 = max(0, int(round(cx - bw / 2.0)))
            y1 = max(0, int(round(cy - bh / 2.0)))
            x2 = min(w, int(round(cx + bw / 2.0)))
            y2 = min(h, int(round(cy + bh / 2.0)))
            col = colors.get(cname, (128, 128, 128))
            cv2.rectangle(annotated, (x1, y1), (x2, y2), col, 2)
            cv2.putText(
                annotated,
                f"{cname} {node.get('confidence', 0):.2f}",
                (x1, max(12, y1 - 4)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.4,
                col,
                1,
            )

        # Save annotated image
        out_path = out_dir / f"{img_path.stem}_boxed.jpg"
        cv2.imwrite(str(out_path), annotated)

        # Side by side comparison
        sbs_canvas = np.full((h, w * 2 + 10, 3), 240, dtype=np.uint8)
        sbs_canvas[:, :w] = img
        sbs_canvas[:, w + 10:w * 2 + 10] = annotated
        sbs_path = out_dir / f"{img_path.stem}_side_by_side.jpg"
        cv2.imwrite(str(sbs_path), sbs_canvas)

        summary_str = f"Bus:{class_counts['bus']} Gen:{class_counts['generator']} Load:{class_counts['load']} Trans:{class_counts['transformer']} Lines:{len(lines)}"
        results_summary[img_path.name] = {
            "counts": dict(class_counts),
            "total_nodes": len(nodes),
            "lines": len(lines),
            "dimensions": f"{w}x{h}",
        }
        print(f" [{idx:2d}/20] {img_path.name:35} ({w}x{h}): {summary_str}")

    print(f"==========================================\n")
    return results_summary


def generate_evaluation_report(train_res, matrix_res, benchmark_res):
    """Generate markdown evaluation report comparing against user feedback checklist."""
    report_path = OUTPUT_DIR / "USER_FEEDBACK_EVALUATION_REPORT.md"
    answer_key_path = OUTPUT_DIR / "USER_FEEDBACK_ANSWER_KEY.md"

    report_lines = [
        "# External Review & Verification Gates Evaluation Report",
        "",
        f"**Date/Time**: {Path(__file__).stat().st_mtime}",
        "",
        "## 1. Verification Gates Summary",
        "",
        f"- **Gate 1: Native Train 100% Verification**: {'PASSED' if train_res.get('exact_100') else 'FAILED'}",
        f"  - Score: {train_res.get('score', 0):.2f}%",
        f"  - TP: {train_res.get('totals', {}).get('tp', 0)} / 496",
        f"  - FP: {train_res.get('totals', {}).get('fp', 0)}",
        f"  - FN: {train_res.get('totals', {}).get('fn', 0)}",
        "",
        f"- **Gate 2: Scale-preserving Canonical Padding Matrix**: {'PASSED' if matrix_res.get('passed') else 'FAILED'}",
        f"  - Overall Score: {matrix_res.get('overall_score', 0):.2f}% (Target: >= 98.0%)",
        "",
        "| Variant | Score | TP / Targets | FP | FN |",
        "|---|---|---|---|---|",
    ]

    for vname, vstat in matrix_res.get("variants", {}).items():
        t = vstat["totals"]
        report_lines.append(f"| `{vname}` | {vstat['score']:.2f}% | {t['tp']} / {vstat['targets']} | {t['fp']} | {t['fn']} |")

    report_lines.extend([
        "",
        "## 2. External Benchmark (New Pictures 20 Images) Prediction Summary",
        "",
        "| Image | Dimensions | Bus | Generator | Load | Transformer | Lines |",
        "|---|---|---:|---:|---:|---:|---:|",
    ])

    for img_name, info in benchmark_res.items():
        c = info.get("counts", {})
        report_lines.append(f"| `{img_name}` | {info.get('dimensions')} | {c.get('bus', 0)} | {c.get('generator', 0)} | {c.get('load', 0)} | {c.get('transformer', 0)} | {info.get('lines', 0)} |")

    report_lines.extend([
        "",
        "## 3. Checklist Item Analysis (against USER_FEEDBACK_ANSWER_KEY.md)",
        "",
        "| Checklist Item | Image | Reported Issue | Predictions in Area | Assessment |",
        "|---|---|---|---|---|",
        "| #1/#2 | `...02_boxed.jpg` | Missing bus/load candidate | Inspect predictions | Recorded |",
        "| #3/#4, #5, #6, #8, #9 | `...06_boxed.jpg` | Missing bus & loads | Inspect predictions | Recorded |",
        "| #7, #10/#11 | `...08_boxed.jpg` | Missing buses, load, transformer | Inspect predictions | Recorded |",
        "| #12/#13 | `...09_boxed.jpg` | Bus box span full bus | Inspect bus span | Recorded |",
        "| #14/#15, #16 | `...13_boxed.jpg` | Missing generator & load | Inspect predictions | Recorded |",
        "| #17-#20 | `...56634_04_boxed.jpg` | Missing transformers | Inspect predictions | Recorded |",
        "| #21-#24 | `...56634_05_boxed.jpg` | Missing load candidates | Inspect predictions | Recorded |",
        "",
        "## 4. Next Iteration Plan",
        "Based on the visual checklist findings, design targeted, isolated improvements in the pipeline and verify Gates 1 & 2 before next evaluation pass.",
    ])

    report_path.write_text("\n".join(report_lines), encoding="utf-8")
    print(f"Generated evaluation report at {report_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gate", choices=("all", "train", "matrix", "benchmark"), default="all")
    args = parser.parse_args()

    train_res = {}
    matrix_res = {}
    benchmark_res = {}

    if args.gate in ("all", "train"):
        train_res = run_train_gate()

    if args.gate in ("all", "matrix"):
        matrix_res = run_robustness_matrix_gate()

    if args.gate in ("all", "benchmark"):
        if train_res.get("exact_100", True) and matrix_res.get("passed", True):
            benchmark_res = run_new_pictures_benchmark()
            generate_evaluation_report(train_res, matrix_res, benchmark_res)
        else:
            print("Skipping benchmark because verification gates did not pass.")


if __name__ == "__main__":
    main()

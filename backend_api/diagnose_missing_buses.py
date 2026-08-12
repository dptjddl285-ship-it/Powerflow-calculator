"""39bus 도면에서 지정한 모선 번호의 누락 원인을 단계별로 확인하는 진단 도구."""

from __future__ import annotations

from pathlib import Path
import sys

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cv_bus_refined_experiment as cvbus


# (이름, x1, y1, x2, y2) - 원본 39bus 그림에서 각 번호와 그 주변 모선이 들어가는 영역
TARGETS = [
    ("bus_6", 170, 535, 395, 635),
    ("bus_11", 325, 600, 475, 710),
    ("bus_16", 525, 285, 740, 395),
    ("bus_29", 835, 55, 955, 190),
]


def save(path: Path, image: np.ndarray) -> None:
    ok, data = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 96])
    if not ok:
        raise RuntimeError(path)
    data.tofile(str(path))


def crop(image: np.ndarray, box: tuple[int, int, int, int]) -> np.ndarray:
    x1, y1, x2, y2 = box
    return image[y1:y2, x1:x2]


def main() -> None:
    source = cvbus.ROOT / "학습 IEEE" / "39bus.jpg"
    out = cvbus.OUTPUT / "39bus" / "missing_bus_diagnosis"
    out.mkdir(parents=True, exist_ok=True)

    image = cvbus.read_image(source)
    binary = cvbus.binarize_and_repair(image)
    thin = cvbus.estimate_thin_line_width(binary)
    horizontal_mask, vertical_mask = cvbus.directional_bar_masks(
        binary, max(5, round(thin * 1.6))
    )
    raw_mask = cv2.bitwise_or(horizontal_mask, vertical_mask)
    h_bars, _, _ = cvbus.collect_bars(horizontal_mask, binary, "horizontal", thin)
    v_bars, _, _ = cvbus.collect_bars(vertical_mask, binary, "vertical", thin)
    traced = cvbus.pixel_path_connected_buses(binary, cvbus.deduplicate(h_bars + v_bars), thin)
    final = cvbus.topology_refined_buses(binary, traced, thin, endpoint_exclusion_ratio=0.05)

    raw_bgr = cv2.cvtColor(
        cv2.resize(raw_mask, (image.shape[1], image.shape[0]), interpolation=cv2.INTER_AREA),
        cv2.COLOR_GRAY2BGR,
    )
    final_overlay = cvbus.draw(image, final, [], "final topology candidates")
    binary_bgr = cv2.cvtColor(
        cv2.resize(binary, (image.shape[1], image.shape[0]), interpolation=cv2.INTER_AREA),
        cv2.COLOR_GRAY2BGR,
    )

    rows = [
        "target,raw_mask_pixels,final_candidate_overlaps,interpretation",
    ]
    for name, x1, y1, x2, y2 in TARGETS:
        raw_pixels = int(np.count_nonzero(raw_mask[y1 * cvbus.SCALE:y2 * cvbus.SCALE,
                                                  x1 * cvbus.SCALE:x2 * cvbus.SCALE]))
        final_count = 0
        for bar in final:
            bx1, by1 = bar.x / cvbus.SCALE, bar.y / cvbus.SCALE
            bx2, by2 = (bar.x + bar.w) / cvbus.SCALE, (bar.y + bar.h) / cvbus.SCALE
            if max(x1, bx1) < min(x2, bx2) and max(y1, by1) < min(y2, by2):
                final_count += 1
        panels = [crop(image, (x1, y1, x2, y2)), crop(binary_bgr, (x1, y1, x2, y2)),
                  crop(raw_bgr, (x1, y1, x2, y2)), crop(final_overlay, (x1, y1, x2, y2))]
        labeled = []
        for title, panel in zip(["original", "binary + repair", "raw bar mask", "final candidates"], panels):
            cv2.rectangle(panel, (0, 0), (panel.shape[1], 23), (255, 255, 255), -1)
            cv2.putText(panel, title, (5, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 1, cv2.LINE_AA)
            labeled.append(panel)
        comparison = cv2.hconcat(labeled)
        save(out / f"{name}_comparison.jpg", comparison)
        # 번호와 실제 막대를 눈으로 대응할 수 있도록 원본/최종 결과를 3배 확대한 이미지도 남긴다.
        zoom = cv2.hconcat([panels[0], panels[3]])
        zoom = cv2.resize(zoom, None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST)
        save(out / f"{name}_zoom.jpg", zoom)
        interpretation = "candidate remains" if final_count else "not a final bus candidate"
        rows.append(f"{name},{raw_pixels},{final_count},{interpretation}")

    (out / "summary.csv").write_text("\n".join(rows) + "\n", encoding="utf-8-sig")
    print(f"saved: {out}")


if __name__ == "__main__":
    main()

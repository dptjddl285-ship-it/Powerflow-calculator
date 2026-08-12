"""24bus 이미지에서 OpenCV 규칙만으로 모선(bus bar)을 찾는 비교 실험.

YOLO 및 기존 API 코드는 변경하지 않는다. 실행하면 프로젝트 루트의
`cv_bus_comparison` 폴더에 방법별 비교 이미지와 검출 목록을 생성한다.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import csv
import cv2
import numpy as np


ROOT = Path(__file__).resolve().parent.parent
IMAGE_PATHS = [
    ROOT / "학습 IEEE" / "24bus.jpg",
    ROOT / "학습 IEEE" / "IEEE24bus.jpg",
    ROOT / "학습 IEEE" / "39bus.jpg",
]
OUTPUT_DIR = ROOT / "cv_bus_comparison"


@dataclass
class Candidate:
    x: int
    y: int
    w: int
    h: int
    orientation: str
    fill_ratio: float
    connections: int = 0
    reason: str = "accepted"


def load_image(path: Path) -> np.ndarray:
    """Windows 한글 경로도 안전하게 읽는다."""
    image = cv2.imdecode(np.fromfile(str(path), dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise FileNotFoundError(f"이미지를 읽을 수 없습니다: {path}")
    return image


def make_binary(gray: np.ndarray, method: str) -> np.ndarray:
    if method == "fixed":
        # 24bus의 검은 선/흰 배경에 맞춘 단순 임계값
        _, binary = cv2.threshold(gray, 170, 255, cv2.THRESH_BINARY_INV)
    elif method == "otsu":
        _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    elif method == "adaptive":
        binary = cv2.adaptiveThreshold(
            gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
            cv2.THRESH_BINARY_INV, 31, 8,
        )
    else:
        raise ValueError(method)
    return binary


def extract_bus_mask(binary: np.ndarray, kernel_length: int, kernel_thickness: int) -> np.ndarray:
    """가늘고 긴 선로는 제거하고, 두께가 있는 가로/세로 모선만 남긴다."""
    horizontal_kernel = cv2.getStructuringElement(
        cv2.MORPH_RECT, (kernel_length, kernel_thickness)
    )
    vertical_kernel = cv2.getStructuringElement(
        cv2.MORPH_RECT, (kernel_thickness, kernel_length)
    )
    horizontal = cv2.morphologyEx(binary, cv2.MORPH_OPEN, horizontal_kernel)
    vertical = cv2.morphologyEx(binary, cv2.MORPH_OPEN, vertical_kernel)
    return cv2.bitwise_or(horizontal, vertical)


def count_runs(values: list[bool]) -> int:
    """연속된 픽셀 묶음 하나를 선로 한 가닥으로 센다."""
    count = 0
    in_run = False
    for value in values:
        if value and not in_run:
            count += 1
        in_run = value
    return count


def count_connection_evidence(binary: np.ndarray, candidate: Candidate) -> int:
    """모선 막대에 닿는 직교 방향의 선로(또는 기기 리드선) 개수를 센다.

    가로 모선에는 위/아래에서 들어오는 세로 선을, 세로 모선에는 좌/우에서
    들어오는 가로 선을 찾는다. 글자 숫자는 이 길이를 갖는 직선 연결을 만들기
    어려우므로, 얇은 39bus 모선을 선로/숫자와 구별하는 보조 조건이 된다.
    """
    h_img, w_img = binary.shape[:2]
    lead_length = max(8, int(min(w_img, h_img) * 0.012))
    if candidate.orientation == "horizontal":
        support = cv2.morphologyEx(
            binary, cv2.MORPH_OPEN,
            cv2.getStructuringElement(cv2.MORPH_RECT, (1, lead_length)),
        )
        x1 = max(0, candidate.x - 2)
        x2 = min(w_img, candidate.x + candidate.w + 2)
        above = [bool(np.any(support[max(0, candidate.y - lead_length):candidate.y, x]))
                 for x in range(x1, x2)]
        below = [bool(np.any(support[candidate.y + candidate.h:min(h_img, candidate.y + candidate.h + lead_length), x]))
                 for x in range(x1, x2)]
        return count_runs(above) + count_runs(below)

    support = cv2.morphologyEx(
        binary, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (lead_length, 1)),
    )
    y1 = max(0, candidate.y - 2)
    y2 = min(h_img, candidate.y + candidate.h + 2)
    left = [bool(np.any(support[y, max(0, candidate.x - lead_length):candidate.x]))
            for y in range(y1, y2)]
    right = [bool(np.any(support[y, candidate.x + candidate.w:min(w_img, candidate.x + candidate.w + lead_length)]))
             for y in range(y1, y2)]
    return count_runs(left) + count_runs(right)


def classify_candidates(mask: np.ndarray, binary: np.ndarray, connection_aware: bool = False) -> tuple[list[Candidate], list[Candidate]]:
    """모선의 기하 규칙으로 후보를 승인/거절한다.

    - 두께 4px 이상: 1px 선로와 숫자 획 제거
    - 길이 18px 이상: 숫자/문자 조각 제거
    - 가로 또는 세로가 최소 2.5배 길어야 함
    - 면적이 이미지의 4% 이상이면 비정상 큰 박스로 제거
    - 채움 비율이 높아야 함: 문자/화살표 등 불규칙 물체 제거
    """
    h_img, w_img = mask.shape[:2]
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    accepted: list[Candidate] = []
    rejected: list[Candidate] = []

    for contour in contours:
        x, y, w, h = cv2.boundingRect(contour)
        contour_area = cv2.contourArea(contour)
        box_area = max(w * h, 1)
        fill_ratio = contour_area / box_area
        long_side, short_side = max(w, h), min(w, h)
        orientation = "horizontal" if w >= h else "vertical"
        candidate = Candidate(x, y, w, h, orientation, fill_ratio)
        candidate.connections = count_connection_evidence(binary, candidate)

        if (w * h) / (w_img * h_img) > 0.04:
            candidate.reason = "rejected: box too large"
        elif long_side < (14 if connection_aware else 18):
            candidate.reason = "rejected: too short"
        elif short_side < (2 if connection_aware else 4):
            candidate.reason = "rejected: too thin (line/text)"
        elif long_side / max(short_side, 1) < (3.0 if connection_aware else 2.5):
            candidate.reason = "rejected: not bar-shaped"
        elif fill_ratio < (0.38 if connection_aware else 0.55):
            candidate.reason = "rejected: low fill ratio"
        elif connection_aware and candidate.connections < 1:
            candidate.reason = "rejected: no line/device connection"

        if candidate.reason == "accepted":
            accepted.append(candidate)
        else:
            rejected.append(candidate)

    # 같은 모선을 수평/수직 마스크가 중복 검출할 수 있어 IoU로 하나만 남긴다.
    accepted.sort(key=lambda c: c.w * c.h, reverse=True)
    deduplicated: list[Candidate] = []
    for candidate in accepted:
        overlap = False
        for saved in deduplicated:
            ix1, iy1 = max(candidate.x, saved.x), max(candidate.y, saved.y)
            ix2 = min(candidate.x + candidate.w, saved.x + saved.w)
            iy2 = min(candidate.y + candidate.h, saved.y + saved.h)
            intersection = max(0, ix2 - ix1) * max(0, iy2 - iy1)
            union = candidate.w * candidate.h + saved.w * saved.h - intersection
            if union and intersection / union > 0.35:
                overlap = True
                break
        if not overlap:
            deduplicated.append(candidate)
    return deduplicated, rejected


def overlaps(first: Candidate, second: Candidate) -> bool:
    ix1, iy1 = max(first.x, second.x), max(first.y, second.y)
    ix2 = min(first.x + first.w, second.x + second.w)
    iy2 = min(first.y + first.h, second.y + second.h)
    intersection = max(0, ix2 - ix1) * max(0, iy2 - iy1)
    union = first.w * first.h + second.w * second.h - intersection
    return bool(union and intersection / union > 0.30)


def add_connection_verified_candidates(base: list[Candidate], sensitive: list[Candidate], image_shape: tuple[int, int]) -> list[Candidate]:
    """견고한 굵은 모선은 보존하고, 얇은 후보는 연결 증거가 강할 때만 추가한다."""
    h_img, w_img = image_shape
    merged = list(base)
    for candidate in sensitive:
        long_side = max(candidate.w, candidate.h)
        axis_size = w_img if candidate.orientation == "horizontal" else h_img
        # 긴 직선 선로는 모선으로 보지 않는다. 39bus의 상단 선로 같은 오검출을 제거한다.
        if long_side > axis_size * 0.18:
            continue
        # 약한(얇은) 후보는 양쪽/여러 지점의 실제 연결이 있어야 새 모선으로 추가한다.
        if candidate.connections < 2:
            continue
        if candidate.fill_ratio < 0.45:
            continue
        if any(overlaps(candidate, saved) for saved in merged):
            continue
        merged.append(candidate)
    return merged


def draw_result(image: np.ndarray, candidates: list[Candidate], rejected: list[Candidate], title: str) -> np.ndarray:
    canvas = image.copy()
    for candidate in rejected:
        cv2.rectangle(canvas, (candidate.x, candidate.y),
                      (candidate.x + candidate.w, candidate.y + candidate.h), (120, 120, 120), 1)
    for number, candidate in enumerate(candidates, start=1):
        color = (0, 180, 0) if candidate.orientation == "horizontal" else (255, 100, 0)
        cv2.rectangle(canvas, (candidate.x, candidate.y),
                      (candidate.x + candidate.w, candidate.y + candidate.h), color, 2)
        cv2.putText(canvas, f"B{number}({candidate.connections})", (candidate.x, max(14, candidate.y - 4)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.42, color, 1, cv2.LINE_AA)
    cv2.rectangle(canvas, (0, 0), (canvas.shape[1], 28), (255, 255, 255), -1)
    cv2.putText(canvas, title, (8, 19), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 0), 1, cv2.LINE_AA)
    return canvas


def save_image(path: Path, image: np.ndarray) -> None:
    ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 96])
    if not ok:
        raise RuntimeError(f"이미지 저장 실패: {path}")
    encoded.tofile(str(path))


def main() -> None:
    OUTPUT_DIR.mkdir(exist_ok=True)

    # 서로 다른 전처리/모폴로지 설정. 결과를 보고 가장 안정적인 규칙을 고른다.
    variants = [
        ("01_fixed_balanced", "fixed", 19, 5),
        ("02_otsu_strict", "otsu", 23, 5),
        ("03_adaptive_sensitive", "adaptive", 17, 4, False),
        # 39bus처럼 얇은 모선을 위한 민감 후보 추출 + 연결선 검증 조합.
        ("04_connection_aware", "otsu", 13, 3, True),
        ("05_connection_refined", "otsu", 13, 3, True),
    ]
    for image_path in IMAGE_PATHS:
        image_output_dir = OUTPUT_DIR / image_path.stem
        image_output_dir.mkdir(exist_ok=True)
        image = load_image(image_path)
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        all_rows: list[dict[str, object]] = []
        base_binary = make_binary(gray, "fixed")
        base_mask = extract_bus_mask(base_binary, 19, 5)
        base_candidates, _ = classify_candidates(base_mask, base_binary)

        for variant in variants:
            if len(variant) == 4:
                variant_name, threshold_method, kernel_length, kernel_thickness = variant
                connection_aware = False
            else:
                variant_name, threshold_method, kernel_length, kernel_thickness, connection_aware = variant
            binary = make_binary(gray, threshold_method)
            mask = extract_bus_mask(binary, kernel_length, kernel_thickness)
            accepted, rejected = classify_candidates(mask, binary, connection_aware)
            if variant_name == "05_connection_refined":
                accepted = add_connection_verified_candidates(
                    base_candidates, accepted, image.shape[:2]
                )

            binary_bgr = cv2.cvtColor(binary, cv2.COLOR_GRAY2BGR)
            mask_bgr = cv2.cvtColor(mask, cv2.COLOR_GRAY2BGR)
            result = draw_result(image, accepted, rejected,
                                 f"{variant_name}: {len(accepted)} bus candidates")
            comparison = cv2.hconcat([image, binary_bgr, mask_bgr, result])

            save_image(image_output_dir / f"{variant_name}_comparison.jpg", comparison)
            save_image(image_output_dir / f"{variant_name}_result.jpg", result)
            for number, candidate in enumerate(accepted, start=1):
                all_rows.append({
                    "variant": variant_name, "bus_id": f"B{number}",
                    "orientation": candidate.orientation, "x": candidate.x, "y": candidate.y,
                    "width": candidate.w, "height": candidate.h,
                "fill_ratio": f"{candidate.fill_ratio:.2f}", "connections": candidate.connections, "status": "accepted",
                })
            for candidate in rejected:
                all_rows.append({
                    "variant": variant_name, "bus_id": "-", "orientation": candidate.orientation,
                    "x": candidate.x, "y": candidate.y, "width": candidate.w, "height": candidate.h,
                "fill_ratio": f"{candidate.fill_ratio:.2f}", "connections": candidate.connections, "status": candidate.reason,
                })
            print(f"{image_path.name} / {variant_name}: accepted={len(accepted)}, rejected={len(rejected)}")

        with (image_output_dir / "detection_log.csv").open("w", newline="", encoding="utf-8-sig") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=all_rows[0].keys())
            writer.writeheader()
            writer.writerows(all_rows)

    (OUTPUT_DIR / "README.txt").write_text(
        "24bus OpenCV 모선 인식 비교 결과\n\n"
        "comparison 이미지는 [원본 | 이진화 | 모선 후보 마스크 | 최종 박스] 순서입니다.\n"
        "초록 박스=가로 모선, 주황 박스=세로 모선, 회색 박스=규칙으로 제거된 후보입니다.\n"
        "detection_log.csv에는 모든 후보와 제거 사유가 들어 있습니다.\n",
        encoding="utf-8",
    )
    print(f"저장 완료: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()

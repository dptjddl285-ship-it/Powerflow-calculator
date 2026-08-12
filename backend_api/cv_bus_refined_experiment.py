"""두께/형태/기기 리드선 조건을 합친 OpenCV 모선 인식 실험.

실제 API에는 연결하지 않는 진단 전용 파일이다.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import csv
import cv2
import numpy as np


ROOT = Path(__file__).resolve().parent.parent
INPUTS = [
    ROOT / "학습 IEEE" / "IEEE24bus.jpg",
    ROOT / "학습 IEEE" / "39bus.jpg",
    ROOT / "학습 IEEE" / "14bus.jpg",
]
OUTPUT = ROOT / "cv_bus_topology_recovery_comparison"
SCALE = 2


@dataclass
class Bar:
    x: int
    y: int
    w: int
    h: int
    orientation: str
    profile_score: float
    network_connections: int = 0
    traced_components: int = 0
    perpendicular_branches: int = 0
    bent_endpoints: int = 0
    needs_topology_recovery: bool = False
    reason: str = "accepted"


def read_image(path: Path) -> np.ndarray:
    image = cv2.imdecode(np.fromfile(str(path), dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise FileNotFoundError(path)
    return image


def binarize_and_repair(image: np.ndarray) -> np.ndarray:
    """확대 후 이진화하고, 1px 이내의 같은 방향 끊김만 잇는다."""
    large = cv2.resize(image, None, fx=SCALE, fy=SCALE, interpolation=cv2.INTER_CUBIC)
    gray = cv2.cvtColor(large, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)

    # 원본 기준 1px 정도의 틈(확대 후 최대 2px)을 방향별로만 메운다.
    horizontal = cv2.morphologyEx(binary, cv2.MORPH_CLOSE,
                                  cv2.getStructuringElement(cv2.MORPH_RECT, (5, 1)))
    vertical = cv2.morphologyEx(binary, cv2.MORPH_CLOSE,
                                cv2.getStructuringElement(cv2.MORPH_RECT, (1, 5)))
    return cv2.bitwise_or(horizontal, vertical)


def estimate_thin_line_width(binary: np.ndarray) -> int:
    """도면 내부의 일반 선로 폭을 거리 변환으로 추정한다."""
    distances = cv2.distanceTransform(binary, cv2.DIST_L2, 3)
    values = distances[distances > 0]
    # 대부분의 전경은 얇은 선/문자 획이므로 중앙값을 일반 선로 폭으로 사용한다.
    return max(2, int(round(float(np.median(values)) * 2)))


def directional_bar_masks(binary: np.ndarray, min_thickness: int) -> tuple[np.ndarray, np.ndarray]:
    # 선로보다 두꺼운 막대만 남긴다. 길이는 확대 후 약 14px(원본 7px) 이상.
    horizontal = cv2.morphologyEx(
        binary, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (28, min_thickness)),
    )
    vertical = cv2.morphologyEx(
        binary, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (min_thickness, 28)),
    )
    return horizontal, vertical


def profile_score(binary: np.ndarray, bar: Bar) -> float:
    """막대 길이 전체에서 두께가 균일한지 측정한다.

    숫자/문자는 검은 픽셀이 끊기거나 꺾여 점수가 낮고, bus bar는 거의 모든
    단면에서 일정한 두께를 유지한다.
    """
    crop = binary[bar.y:bar.y + bar.h, bar.x:bar.x + bar.w]
    if crop.size == 0:
        return 0.0
    projections = np.sum(crop > 0, axis=0 if bar.orientation == "horizontal" else 1)
    nonzero = projections[projections > 0]
    if len(nonzero) == 0:
        return 0.0
    p10, p90 = np.percentile(nonzero, [10, 90])
    coverage = len(nonzero) / len(projections)
    return float(coverage * (p10 / max(p90, 1)))


def touches_device_lead(binary: np.ndarray, bar: Bar, thin_line_width: int) -> bool:
    """후보가 굵은 막대가 아니라 기기 쪽으로 향한 얇은 리드선인지 보수적으로 확인.

    이 규칙은 '기기에 연결되어 있다' 자체가 아니라, 후보의 단면이 일반 선로 수준으로
    얇고 긴 경우에만 적용한다. 발전기와 직접 연결된 진짜 bus bar를 제거하지 않기 위함이다.
    """
    short_side = min(bar.w, bar.h)
    if short_side >= thin_line_width * 1.6:
        return False
    # 얇은 후보는 이미 bus로 인정하지 않으므로, 이 함수는 제거 사유를 명확히 남긴다.
    return True


def collect_bars(
    mask: np.ndarray,
    binary: np.ndarray,
    orientation: str,
    thin_line_width: int,
) -> tuple[list[Bar], list[Bar], list[Bar]]:
    """Return clear candidates, topology-recovery candidates, and hard rejects.

    A real bus can be slightly long or have an uneven profile at a genuine
    connection point.  Such candidates are deferred to the topology stage,
    where they must prove that they are straight and multiply connected.
    """
    accepted: list[Bar] = []
    recovery_candidates: list[Bar] = []
    rejected: list[Bar] = []
    height, width = binary.shape
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    for contour in contours:
        x, y, w, h = cv2.boundingRect(contour)
        bar = Bar(x, y, w, h, orientation, 0.0)
        long_side, short_side = max(w, h), min(w, h)
        axis_size = width if orientation == "horizontal" else height
        bar.profile_score = profile_score(binary, bar)

        if long_side > axis_size * 0.35:
            bar.reason = "rejected: page-spanning candidate"
        elif short_side < thin_line_width * 1.6:
            bar.reason = "rejected: thin device lead / line"
        elif long_side / max(short_side, 1) < 2.5:
            bar.reason = "rejected: not bar-shaped"
        elif touches_device_lead(binary, bar, thin_line_width):
            bar.reason = "rejected: device lead"
        elif bar.profile_score < 0.60:
            bar.reason = "rejected: unstable profile (text/symbol)"
        elif long_side > axis_size * 0.18 or bar.profile_score < 0.70:
            bar.needs_topology_recovery = True
            if long_side > axis_size * 0.18 and bar.profile_score < 0.70:
                bar.reason = "pending recovery: long and uneven"
            elif long_side > axis_size * 0.18:
                bar.reason = "pending recovery: long"
            else:
                bar.reason = "pending recovery: uneven profile"

        if bar.reason == "accepted":
            accepted.append(bar)
        elif bar.needs_topology_recovery:
            recovery_candidates.append(bar)
        else:
            rejected.append(bar)
    return accepted, recovery_candidates, rejected


def deduplicate(bars: list[Bar]) -> list[Bar]:
    saved: list[Bar] = []
    for bar in sorted(bars, key=lambda item: item.w * item.h, reverse=True):
        duplicate = False
        for other in saved:
            ix1, iy1 = max(bar.x, other.x), max(bar.y, other.y)
            ix2 = min(bar.x + bar.w, other.x + other.w)
            iy2 = min(bar.y + bar.h, other.y + other.h)
            intersection = max(0, ix2 - ix1) * max(0, iy2 - iy1)
            union = bar.w * bar.h + other.w * other.h - intersection
            if union and intersection / union > 0.30:
                duplicate = True
                break
        if not duplicate:
            saved.append(bar)
    return saved


def has_network_connection(binary: np.ndarray, bar: Bar, thin_line_width: int) -> bool:
    """후보 박스 바깥으로 이어지는 실제 직선 선로가 하나 이상 있는지 확인한다.

    숫자/문자는 자체 획만 있고 박스 바깥의 긴 수평·수직 선로와 이어지지 않는다.
    반면 실제 bus는 적어도 한 방향으로 선로, 리드선 또는 다른 bus와 접속한다.
    """
    h_img, w_img = binary.shape
    reach = max(12, thin_line_width * 5)
    line_thickness = max(2, thin_line_width)
    horizontal_lines = cv2.morphologyEx(
        binary, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (reach, line_thickness)),
    )
    vertical_lines = cv2.morphologyEx(
        binary, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (line_thickness, reach)),
    )

    # 후보 내부가 아니라 바깥 띠만 검사한다. 따라서 숫자 자신의 획은 접속으로 세지 않는다.
    margin = max(1, thin_line_width // 2)
    x1, x2 = max(0, bar.x + margin), min(w_img, bar.x + bar.w - margin)
    y1, y2 = max(0, bar.y + margin), min(h_img, bar.y + bar.h - margin)
    above = np.any(vertical_lines[max(0, bar.y - reach):bar.y, x1:x2])
    below = np.any(vertical_lines[bar.y + bar.h:min(h_img, bar.y + bar.h + reach), x1:x2])
    left = np.any(horizontal_lines[y1:y2, max(0, bar.x - reach):bar.x])
    right = np.any(horizontal_lines[y1:y2, bar.x + bar.w:min(w_img, bar.x + bar.w + reach)])
    bar.network_connections = int(above) + int(below) + int(left) + int(right)
    return bar.network_connections > 0


def skeletonize(binary: np.ndarray) -> np.ndarray:
    """opencv-contrib 없이도 동작하는 형태학적 skeleton 추출."""
    working = binary.copy()
    skeleton = np.zeros_like(binary)
    element = cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3))
    while cv2.countNonZero(working) > 0:
        eroded = cv2.erode(working, element)
        opened = cv2.dilate(eroded, element)
        edge = cv2.subtract(working, opened)
        skeleton = cv2.bitwise_or(skeleton, edge)
        working = eroded
    return skeleton


def _network_without_candidate(skeleton: np.ndarray, bar: Bar) -> np.ndarray:
    """Return the skeleton with only the candidate under examination removed."""
    network = skeleton.copy()
    cv2.rectangle(network, (bar.x, bar.y), (bar.x + bar.w, bar.y + bar.h), 0, -1)
    return network


def _pixel_path_component_count(network: np.ndarray, bar: Bar) -> int:
    """Count real line components touching the one-pixel ring around a bar."""
    count, labels, stats, _ = cv2.connectedComponentsWithStats(network, connectivity=8)
    local_mask = np.zeros_like(network)
    cv2.rectangle(local_mask, (bar.x, bar.y), (bar.x + bar.w, bar.y + bar.h), 255, -1)
    ring = cv2.dilate(local_mask, np.ones((3, 3), np.uint8))
    ring[local_mask > 0] = 0
    component_ids = np.unique(labels[(ring > 0) & (network > 0)])
    min_path_pixels = 24
    return sum(
        component_id != 0 and stats[component_id, cv2.CC_STAT_AREA] >= min_path_pixels
        for component_id in component_ids
    )


def _pixel_path_connected_buses_global(binary: np.ndarray, buses: list[Bar]) -> list[Bar]:
    """후보 경계에서 출발한 실제 픽셀 경로가 선로망까지 이어지는지 검사한다.

    모든 후보 막대를 임시로 지운 뒤 선로를 skeleton으로 만든다. 이후 각 막대의
    바로 바깥 1픽셀 ring에서 닿는 연결 성분을 찾는다. 공중 숫자는 ring에 닿는
    긴 선로 성분이 없어 제거되고, 진짜 bus는 선로/리드선 경로가 남는다.
    """
    skeleton = skeletonize(binary)
    bar_mask = np.zeros_like(binary)
    for bar in buses:
        cv2.rectangle(bar_mask, (bar.x, bar.y), (bar.x + bar.w, bar.y + bar.h), 255, -1)
    network = skeleton.copy()
    network[bar_mask > 0] = 0
    count, labels, stats, _ = cv2.connectedComponentsWithStats(network, connectivity=8)
    min_path_pixels = 24  # 확대 이미지 기준 원본 약 12px 이상의 실제 선로

    connected: list[Bar] = []
    for bar in buses:
        local_mask = np.zeros_like(binary)
        cv2.rectangle(local_mask, (bar.x, bar.y), (bar.x + bar.w, bar.y + bar.h), 255, -1)
        # 막대 바로 바깥 1px만 본다. 가까이 있지만 끊어진 숫자/텍스트는 통과하지 못한다.
        ring = cv2.dilate(local_mask, np.ones((3, 3), np.uint8))
        ring[local_mask > 0] = 0
        component_ids = np.unique(labels[(ring > 0) & (network > 0)])
        component_ids = [component_id for component_id in component_ids
                         if component_id != 0 and stats[component_id, cv2.CC_STAT_AREA] >= min_path_pixels]
        bar.traced_components = len(component_ids)
        if bar.traced_components:
            connected.append(bar)
    return connected


def _pixel_path_connected_buses_local(
    binary: np.ndarray,
    buses: list[Bar],
    thin_line_width: int,
) -> list[Bar]:
    """Keep candidates with local path or branch evidence.

    Each candidate is examined against the original skeleton with only itself
    removed.  Removing every candidate at once breaks valid connections where
    a nearby bus/line was also proposed as a candidate.
    """
    skeleton = skeletonize(binary)
    connected: list[Bar] = []
    for bar in buses:
        network = _network_without_candidate(skeleton, bar)
        bar.traced_components = _pixel_path_component_count(network, bar)
        local_branches = _perpendicular_branch_count(
            network, bar, thin_line_width, endpoint_exclusion_ratio=0.05
        )
        if bar.traced_components or local_branches:
            connected.append(bar)
    return connected


def pixel_path_connected_buses(
    binary: np.ndarray,
    buses: list[Bar],
    thin_line_width: int | None = None,
) -> list[Bar]:
    """Use the conservative global-mask path check for normal candidates."""
    return _pixel_path_connected_buses_global(binary, buses)


def _count_runs(values: np.ndarray) -> int:
    """True가 연속된 구간 하나를 선로 한 가닥으로 센다."""
    values = np.asarray(values, dtype=bool)
    if not values.size:
        return 0
    return int(np.count_nonzero(values & np.concatenate(([True], ~values[:-1]))))


def _network_after_removing_bars(binary: np.ndarray, buses: list[Bar]) -> np.ndarray:
    """모선 후보를 지운 1px 선로망을 만든다.

    후보 막대 안쪽의 픽셀은 보지 않아, 숫자 자체의 획이 연결선으로 계산되는 것을
    줄인다.
    """
    skeleton = skeletonize(binary)
    bar_mask = np.zeros_like(binary)
    for bar in buses:
        cv2.rectangle(bar_mask, (bar.x, bar.y), (bar.x + bar.w, bar.y + bar.h), 255, -1)
    skeleton[bar_mask > 0] = 0
    return skeleton


def _perpendicular_branch_count(
    network: np.ndarray,
    bar: Bar,
    thin_line_width: int,
    endpoint_exclusion_ratio: float = 0.20,
) -> int:
    """모선의 긴 면으로 직교 방향 선로가 들어오고 나가는 횟수를 센다.

    가로 bus에는 위/아래의 세로 선로, 세로 bus에는 좌/우의 가로 선로만 인정한다.
    숫자의 획은 후보 내부에서만 끝나거나, 길이가 부족해 이 조건을 통과하기 어렵다.
    """
    h_img, w_img = network.shape
    min_lead = max(12, thin_line_width * 5)
    # 외부 선로가 바깥 방향으로 최소 길이만큼 직선인 경우만 남긴다.
    vertical_support = cv2.morphologyEx(
        network,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (1, min_lead)),
    )
    horizontal_support = cv2.morphologyEx(
        network,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (min_lead, 1)),
    )

    # 숫자의 끝 획을 선로로 보지 않도록 후보 양 끝 일부는 제외한다.
    # 실제 bus는 끝 부근에도 선로가 붙을 수 있어 이 비율은 실험 대상이다.
    long_side = max(bar.w, bar.h)
    endpoint_margin = max(thin_line_width, int(long_side * endpoint_exclusion_ratio))
    if bar.orientation == "horizontal":
        x1 = max(0, bar.x + endpoint_margin)
        x2 = min(w_img, bar.x + bar.w - endpoint_margin)
        if x2 <= x1:
            return 0
        above = np.any(vertical_support[max(0, bar.y - min_lead):bar.y, x1:x2], axis=0)
        below = np.any(
            vertical_support[bar.y + bar.h:min(h_img, bar.y + bar.h + min_lead), x1:x2],
            axis=0,
        )
        return _count_runs(above) + _count_runs(below)

    y1 = max(0, bar.y + endpoint_margin)
    y2 = min(h_img, bar.y + bar.h - endpoint_margin)
    if y2 <= y1:
        return 0
    left = np.any(horizontal_support[y1:y2, max(0, bar.x - min_lead):bar.x], axis=1)
    right = np.any(
        horizontal_support[y1:y2, bar.x + bar.w:min(w_img, bar.x + bar.w + min_lead)],
        axis=1,
    )
    return _count_runs(left) + _count_runs(right)


def _bent_endpoint_count(network: np.ndarray, bar: Bar, thin_line_width: int) -> int:
    """후보 끝에서 같은 방향으로 이어진 뒤 직각으로 꺾이는 선로를 센다.

    bus bar는 그 자체가 짧고 곧은 막대다. 반면 선로의 일부가 두껍게 남은 경우는
    막대 끝 밖으로 계속 진행한 뒤 다른 방향으로 꺾이는 패턴을 보인다. 이 규칙은
    후보의 끝에서 *같은 축으로 계속되는 경우*만 검사하므로, bus의 긴 면으로
    직교 접속하는 정상 선로는 제거하지 않는다.
    """
    h_img, w_img = network.shape
    follow = max(16, thin_line_width * 7)
    cross = max(12, thin_line_width * 5)
    horizontal_support = cv2.morphologyEx(
        network,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (follow, 1)),
    )
    vertical_support = cv2.morphologyEx(
        network,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (1, follow)),
    )
    count = 0
    if bar.orientation == "horizontal":
        center_y = bar.y + bar.h // 2
        for edge_x, direction in ((bar.x, -1), (bar.x + bar.w, 1)):
            outer_x = edge_x + direction * follow
            x1, x2 = sorted((edge_x, outer_x))
            x1, x2 = max(0, x1), min(w_img, x2)
            straight = np.any(horizontal_support[max(0, center_y - 1):min(h_img, center_y + 2), x1:x2])
            turn_x1, turn_x2 = max(0, outer_x - 2), min(w_img, outer_x + 3)
            turn = np.any(vertical_support[max(0, center_y - cross):min(h_img, center_y + cross), turn_x1:turn_x2])
            count += int(straight and turn)
    else:
        center_x = bar.x + bar.w // 2
        for edge_y, direction in ((bar.y, -1), (bar.y + bar.h, 1)):
            outer_y = edge_y + direction * follow
            y1, y2 = sorted((edge_y, outer_y))
            y1, y2 = max(0, y1), min(h_img, y2)
            straight = np.any(vertical_support[y1:y2, max(0, center_x - 1):min(w_img, center_x + 2)])
            turn_y1, turn_y2 = max(0, outer_y - 2), min(h_img, outer_y + 3)
            turn = np.any(horizontal_support[turn_y1:turn_y2, max(0, center_x - cross):min(w_img, center_x + cross)])
            count += int(straight and turn)
    return count


def _immediate_endpoint_turn_count(network: np.ndarray, bar: Bar, thin_line_width: int) -> int:
    """Count 90-degree turns attached directly to either end of a candidate.

    The previous bend check removed every candidate first.  When a routed line
    was also found as another candidate, that erased its next segment and hid
    the bend.  Here only the candidate being examined is removed, so the
    actual line path at its endpoint remains visible.
    """
    h_img, w_img = network.shape
    support_length = max(16, thin_line_width * 7)
    cross = max(12, thin_line_width * 5)
    horizontal_support = cv2.morphologyEx(
        network,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (support_length, 1)),
    )
    vertical_support = cv2.morphologyEx(
        network,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (1, support_length)),
    )

    turns = 0
    if bar.orientation == "horizontal":
        center_y = bar.y + bar.h // 2
        for edge_x in (bar.x, bar.x + bar.w):
            x1, x2 = max(0, edge_x - 2), min(w_img, edge_x + 3)
            above = np.any(vertical_support[max(0, center_y - cross):max(0, bar.y), x1:x2])
            below = np.any(
                vertical_support[min(h_img, bar.y + bar.h):min(h_img, center_y + cross), x1:x2]
            )
            turns += int(above or below)
        return turns

    center_x = bar.x + bar.w // 2
    for edge_y in (bar.y, bar.y + bar.h):
        y1, y2 = max(0, edge_y - 2), min(h_img, edge_y + 3)
        left = np.any(horizontal_support[y1:y2, max(0, center_x - cross):max(0, bar.x)])
        right = np.any(
            horizontal_support[y1:y2, min(w_img, bar.x + bar.w):min(w_img, center_x + cross)]
        )
        turns += int(left or right)
    return turns


def topology_refined_buses(
    binary: np.ndarray,
    buses: list[Bar],
    thin_line_width: int,
    endpoint_exclusion_ratio: float = 0.20,
) -> list[Bar]:
    """분기 접속 + 꺾임 조건으로 bus 후보를 한 번 더 걸러낸다."""
    network = _network_after_removing_bars(binary, buses)
    skeleton = skeletonize(binary)
    kept: list[Bar] = []
    for bar in buses:
        bar.perpendicular_branches = _perpendicular_branch_count(
            network, bar, thin_line_width, endpoint_exclusion_ratio
        )
        local_network = _network_without_candidate(skeleton, bar)
        bar.bent_endpoints = max(
            _bent_endpoint_count(network, bar, thin_line_width),
            _immediate_endpoint_turn_count(local_network, bar, thin_line_width),
        )
        # A retained bus must have a real line entering or leaving it.  This
        # excludes detached digits/text and plain line fragments.
        if bar.perpendicular_branches < 1:
            continue
        # A candidate deferred by the length/profile tests needs stronger
        # topology evidence than a clear candidate.  This safely restores
        # real 39-bus bars 6, 11, 16, and 29.
        if bar.needs_topology_recovery:
            if bar.traced_components < 1 or bar.perpendicular_branches < 2:
                continue
        # 짧은 후보는 숫자·문자 획과 구별하기 어려워 실제 선로 분기를 필수로 한다.
        # 반대로 긴 막대는 끝 지점에서만 접속할 수 있으므로, 접속이 없다는 이유만으로
        # 제거하지 않는다. (39bus 상단의 실제 bus 보존)
        ambiguous_length = max(48, thin_line_width * 20)  # 확대 이미지 기준 약 원본 24px
        if max(bar.w, bar.h) < ambiguous_length and bar.perpendicular_branches < 1:
            continue
        # 분기 없이 양 끝으로 서로 다른 픽셀 경로가 빠져나가면, 이는 bus보다
        # 직선으로 통과하는 선로일 가능성이 높다. 39bus 상단 B29가 이 경우였다.
        if bar.perpendicular_branches == 0 and bar.traced_components >= 2:
            continue
        if bar.bent_endpoints > 0:
            continue
        kept.append(bar)
    return kept


def recover_locally_connected_buses(
    binary: np.ndarray,
    buses: list[Bar],
    base_buses: list[Bar],
    thin_line_width: int,
    endpoint_exclusion_ratio: float = 0.05,
) -> list[Bar]:
    """Recover only high-confidence bars hidden by the global path mask.

    This is deliberately stricter than the normal filter.  It is used only
    after the conservative global-mask pipeline has rejected a candidate, so
    ordinary routed line fragments cannot be promoted merely because they
    touch a branch elsewhere in the diagram.
    """
    base_ids = {id(bar) for bar in base_buses}
    skeleton = skeletonize(binary)
    recovered: list[Bar] = []
    for bar in buses:
        if id(bar) in base_ids or bar.orientation != "horizontal":
            continue

        long_side, short_side = max(bar.w, bar.h), min(bar.w, bar.h)
        is_substantial_bus_bar = (
            long_side >= thin_line_width * 25
            and short_side >= thin_line_width * 3.0
            and bar.profile_score >= 0.85
        )
        if not is_substantial_bus_bar:
            continue

        network = _network_without_candidate(skeleton, bar)
        bar.traced_components = _pixel_path_component_count(network, bar)
        bar.perpendicular_branches = _perpendicular_branch_count(
            network, bar, thin_line_width, endpoint_exclusion_ratio
        )
        bar.bent_endpoints = max(
            _bent_endpoint_count(network, bar, thin_line_width),
            _immediate_endpoint_turn_count(network, bar, thin_line_width),
        )
        if bar.bent_endpoints:
            continue

        # Most recovered buses have two or more true local branches.  A short,
        # clearly thick bar with two separate path components also covers a
        # bus connected very close to device/arrow artwork (e.g. bus 7).
        if bar.perpendicular_branches >= 2 or bar.traced_components >= 2:
            recovered.append(bar)
    return recovered


def draw(original: np.ndarray, bars: list[Bar], rejected: list[Bar], title: str) -> np.ndarray:
    canvas = original.copy()
    for bar in rejected:
        x, y, w, h = (round(v / SCALE) for v in (bar.x, bar.y, bar.w, bar.h))
        cv2.rectangle(canvas, (x, y), (x + w, y + h), (180, 180, 180), 1)
    for index, bar in enumerate(bars, start=1):
        x, y, w, h = (round(v / SCALE) for v in (bar.x, bar.y, bar.w, bar.h))
        color = (0, 180, 0) if bar.orientation == "horizontal" else (255, 100, 0)
        cv2.rectangle(canvas, (x, y), (x + w, y + h), color, 2)
        cv2.putText(canvas, f"B{index}", (x, max(14, y - 3)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.42, color, 1, cv2.LINE_AA)
    cv2.rectangle(canvas, (0, 0), (canvas.shape[1], 28), (255, 255, 255), -1)
    cv2.putText(canvas, title, (8, 19), cv2.FONT_HERSHEY_SIMPLEX, 0.52, (0, 0, 0), 1, cv2.LINE_AA)
    return canvas


def save(path: Path, image: np.ndarray) -> None:
    ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 96])
    if not ok:
        raise RuntimeError(path)
    encoded.tofile(str(path))


def detect_cv_buses(image: np.ndarray) -> list[dict[str, float | str]]:
    """Detect bus bars for the API without writing any comparison files.

    The returned coordinates use the original image scale and the same
    ``[x_center, y_center, width, height]`` format as Ultralytics boxes.
    """
    binary = binarize_and_repair(image)
    thin_width = estimate_thin_line_width(binary)
    min_thickness = max(5, int(round(thin_width * 1.6)))
    horizontal_mask, vertical_mask = directional_bar_masks(binary, min_thickness)
    horizontal, recovery_h, _ = collect_bars(
        horizontal_mask, binary, "horizontal", thin_width
    )
    vertical, recovery_v, _ = collect_bars(
        vertical_mask, binary, "vertical", thin_width
    )
    clear_buses = deduplicate(horizontal + vertical)
    recovery_buses = deduplicate(recovery_h + recovery_v)
    candidates = deduplicate(clear_buses + recovery_buses)
    traced_buses = pixel_path_connected_buses(binary, candidates, thin_width)
    base_buses = topology_refined_buses(
        binary, traced_buses, thin_width, endpoint_exclusion_ratio=0.05
    )
    locally_recovered = recover_locally_connected_buses(
        binary, candidates, base_buses, thin_width, endpoint_exclusion_ratio=0.05
    )
    local_ids = {id(bar) for bar in locally_recovered}
    final_buses = deduplicate(base_buses + locally_recovered)
    detected: list[dict[str, float | str]] = []
    for bar in final_buses:
        detected.append({
            "x": (bar.x + bar.w / 2) / SCALE,
            "y": (bar.y + bar.h / 2) / SCALE,
            "w": bar.w / SCALE,
            "h": bar.h / SCALE,
            "orientation": bar.orientation,
            # The local recovery rule is intentionally slightly less certain.
            "confidence": 0.90 if id(bar) in local_ids else 0.95,
        })
    return detected


def main() -> None:
    OUTPUT.mkdir(exist_ok=True)
    for source in INPUTS:
        image = read_image(source)
        binary = binarize_and_repair(image)
        thin_width = estimate_thin_line_width(binary)
        min_thickness = max(5, int(round(thin_width * 1.6)))
        h_mask, v_mask = directional_bar_masks(binary, min_thickness)
        horizontal, recovery_h, rejected_h = collect_bars(h_mask, binary, "horizontal", thin_width)
        vertical, recovery_v, rejected_v = collect_bars(v_mask, binary, "vertical", thin_width)
        clear_buses = deduplicate(horizontal + vertical)
        recovery_buses = deduplicate(recovery_h + recovery_v)
        buses = deduplicate(clear_buses + recovery_buses)
        rejected = rejected_h + rejected_v
        baseline_traced_buses = pixel_path_connected_buses(binary, clear_buses, thin_width)
        baseline_topology_buses = topology_refined_buses(
            binary, baseline_traced_buses, thin_width, endpoint_exclusion_ratio=0.05
        )
        connected_buses = [bar for bar in buses if has_network_connection(binary, bar, thin_width)]
        traced_buses = pixel_path_connected_buses(binary, buses, thin_width)
        base_topology_buses = topology_refined_buses(
            binary, traced_buses, thin_width, endpoint_exclusion_ratio=0.05
        )
        locally_recovered_buses = recover_locally_connected_buses(
            binary, buses, base_topology_buses, thin_width, endpoint_exclusion_ratio=0.05
        )
        topology_buses = deduplicate(base_topology_buses + locally_recovered_buses)
        metrics_buses = deduplicate(traced_buses + locally_recovered_buses)

        folder = OUTPUT / source.stem
        folder.mkdir(exist_ok=True)
        result = draw(image, buses, rejected,
                      f"clear + deferred candidates: {len(buses)}")
        binary_small = cv2.resize(binary, (image.shape[1], image.shape[0]), interpolation=cv2.INTER_AREA)
        mask_small = cv2.resize(cv2.bitwise_or(h_mask, v_mask), (image.shape[1], image.shape[0]), interpolation=cv2.INTER_AREA)
        comparison = cv2.hconcat([
            image,
            cv2.cvtColor(binary_small, cv2.COLOR_GRAY2BGR),
            cv2.cvtColor(mask_small, cv2.COLOR_GRAY2BGR),
            result,
        ])
        save(folder / "comparison.jpg", comparison)
        save(folder / "result.jpg", result)
        connected_result = draw(
            image, connected_buses, rejected,
            f"network-connected candidates only: {len(connected_buses)} bus candidates",
        )
        save(folder / "result_network_connected.jpg", connected_result)
        traced_result = draw(
            image, traced_buses, rejected,
            f"pixel-path-connected candidates only: {len(traced_buses)} bus candidates",
        )
        save(folder / "result_pixel_path_connected.jpg", traced_result)
        baseline_result = draw(
            image, baseline_topology_buses, rejected,
            f"before topology recovery: {len(baseline_topology_buses)} bus candidates",
        )
        save(folder / "result_before_topology_recovery.jpg", baseline_result)
        topology_result = draw(
            image, topology_buses, rejected,
            f"after topology recovery: {len(topology_buses)} bus candidates",
        )
        save(folder / "result_topology_refined.jpg", topology_result)
        save(folder / "before_after_topology_recovery.jpg", cv2.hconcat([baseline_result, topology_result]))
        with (folder / "topology_metrics.csv").open("w", newline="", encoding="utf-8-sig") as file:
            writer = csv.DictWriter(
                file,
                fieldnames=[
                    "candidate", "orientation", "x", "y", "width", "height",
                    "pixel_paths", "perpendicular_branches", "bent_endpoints",
                    "needs_topology_recovery", "kept",
                ],
            )
            writer.writeheader()
            kept_ids = {id(bar) for bar in topology_buses}
            for index, bar in enumerate(metrics_buses, start=1):
                writer.writerow({
                    "candidate": f"B{index}", "orientation": bar.orientation,
                    "x": round(bar.x / SCALE, 1), "y": round(bar.y / SCALE, 1),
                    "width": round(bar.w / SCALE, 1), "height": round(bar.h / SCALE, 1),
                    "pixel_paths": bar.traced_components,
                    "perpendicular_branches": bar.perpendicular_branches,
                    "bent_endpoints": bar.bent_endpoints,
                    "needs_topology_recovery": "yes" if bar.needs_topology_recovery else "no",
                    "kept": "yes" if id(bar) in kept_ids else "no",
                })
        (folder / "summary.txt").write_text(
            f"source={source.name}\n"
            f"estimated_thin_line_width={thin_width / SCALE:.1f}px (original scale)\n"
            f"required_bus_thickness={min_thickness / SCALE:.1f}px (original scale)\n"
            f"accepted_bus_candidates={len(buses)}\n"
            f"clear_candidates={len(clear_buses)}\n"
            f"topology_recovery_candidates={len(recovery_buses)}\n"
            f"network_connected_candidates={len(connected_buses)}\n"
            f"pixel_path_connected_candidates={len(traced_buses)}\n"
            f"locally_recovered_candidates={len(locally_recovered_buses)}\n"
            f"topology_refined_candidates={len(topology_buses)}\n"
            f"rejected_candidates={len(rejected)}\n",
            encoding="utf-8",
        )
        print(f"{source.name}: thin={thin_width / SCALE:.1f}px, bus threshold={min_thickness / SCALE:.1f}px, accepted={len(buses)}, rejected={len(rejected)}")


if __name__ == "__main__":
    main()

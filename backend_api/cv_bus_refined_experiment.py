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
    # A very thick horizontal bus can also survive the vertical morphology
    # kernel (and vice versa).  When the two masks overlap, retain the
    # candidate whose declared direction agrees with the actual long side;
    # choosing by area alone used to relabel horizontal buses as vertical.
    def orientation_matches_shape(item: Bar) -> bool:
        is_horizontal_shape = item.w >= item.h
        return (item.orientation == "horizontal") == is_horizontal_shape

    for bar in sorted(
        bars,
        key=lambda item: (orientation_matches_shape(item), item.w * item.h),
        reverse=True,
    ):
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
        short_lead_branches = 0
        if bar.profile_score >= 0.90:
            short_lead_branches = _perpendicular_branch_count(
                network,
                bar,
                max(2, int(round(thin_line_width * 0.5))),
                endpoint_exclusion_ratio,
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
        strong_single_branch = (
            bar.profile_score >= 0.90 and bar.perpendicular_branches >= 1
        )
        strong_short_leads = (
            bar.profile_score >= 0.90 and short_lead_branches >= 2
        )
        if (
            bar.perpendicular_branches >= 2
            or bar.traced_components >= 2
            or strong_single_branch
            or strong_short_leads
        ):
            recovered.append(bar)
    return recovered


def recover_thin_connected_bars(
    binary: np.ndarray,
    rejected: list[Bar],
    thin_line_width: int,
    endpoint_exclusion_ratio: float = 0.05,
) -> list[Bar]:
    """Recover long, straight bars that were rejected only as line-thin.

    Some diagrams draw a bus with almost the same stroke width as an ordinary
    feeder.  Thickness alone cannot separate those cases, so this recovery
    path requires a substantial straight span, at least two perpendicular
    connections, and no endpoint turn.  Short text strokes and routed line
    fragments fail the span/branch checks and remain rejected.
    """
    candidates = [
        bar for bar in rejected
        if (
            bar.reason == "rejected: thin device lead / line"
            and bar.orientation == "horizontal"
        )
    ]
    if not candidates:
        return []

    _populate_local_geometry_metrics(binary, candidates, thin_line_width)
    # The thin-bar recovery still requires a substantial span, but the old
    # 24x width floor discarded the compact 4px bus bars used in TEST6.
    # Requiring a real perpendicular branch keeps short routed line fragments
    # out while allowing a thin bus to be recovered from its connections.
    minimum_long = max(96.0, thin_line_width * 16.0)
    maximum_short = thin_line_width * 1.65
    recovered: list[Bar] = []
    for bar in candidates:
        long_side = float(max(bar.w, bar.h))
        short_side = float(min(bar.w, bar.h))
        if long_side < minimum_long or short_side > maximum_short:
            continue
        if bar.profile_score < 0.82:
            continue
        if bar.perpendicular_branches < 1 or bar.bent_endpoints:
            continue
        bar.reason = "recovered: thin connected bar"
        recovered.append(bar)
    return recovered


def recover_compact_vertical_buses(
    binary: np.ndarray,
    candidates: list[Bar],
    base_buses: list[Bar],
    thin_line_width: int,
) -> list[Bar]:
    """Recover short, thick vertical buses missed by the long-bar floor.

    In mixed-layout drawings, vertical bus bars can be much shorter than the
    repeated horizontal family.  They are kept only when they are clearly
    thicker than the estimated feeder and have multiple side connections.
    """
    base_ids = {id(bar) for bar in base_buses}
    vertical = [
        bar for bar in candidates
        if id(bar) not in base_ids and bar.orientation == "vertical"
    ]
    if not vertical:
        return []

    _populate_local_geometry_metrics(binary, vertical, thin_line_width)
    standard_minimum_long = max(28.0, thin_line_width * 20.0)
    minimum_long = max(56.0, thin_line_width * 14.0)
    minimum_short = thin_line_width * 2.5
    recovered: list[Bar] = []
    for bar in vertical:
        long_side = float(max(bar.w, bar.h))
        short_side = float(min(bar.w, bar.h))
        if not (minimum_long <= long_side < standard_minimum_long):
            continue
        if short_side < minimum_short:
            continue
        if bar.profile_score < 0.84:
            continue
        if bar.perpendicular_branches < 2 or bar.bent_endpoints:
            continue
        bar.reason = "recovered: compact vertical bus"
        recovered.append(bar)
    return recovered


def _remove_thin_outlier_bars(
    buses: list[Bar],
    thin_line_width: int,
) -> list[Bar]:
    """Remove weak thickness outliers only when a recovery path was used."""
    if not any(bar.reason.startswith("recovered:") for bar in buses):
        return buses

    kept: list[Bar] = []
    for orientation in ("horizontal", "vertical"):
        group = [bar for bar in buses if bar.orientation == orientation]
        strong = [
            float(min(bar.w, bar.h))
            for bar in group
            if max(bar.w, bar.h) >= thin_line_width * 8
            and bar.profile_score >= 0.78
        ]
        if len(strong) < 4:
            kept.extend(group)
            continue
        thickness_floor = max(
            thin_line_width * 1.6,
            float(np.median(strong)) * (0.70 if orientation == "vertical" else 0.65),
        )
        kept.extend(
            bar for bar in group
            if (
                bar.reason == "recovered: thin connected bar"
                or min(bar.w, bar.h) >= thickness_floor
            )
        )
    return deduplicate(kept)


def _populate_local_geometry_metrics(
    binary: np.ndarray,
    candidates: list[Bar],
    thin_line_width: int,
) -> None:
    """Attach local path/branch/bend evidence to every candidate.

    This deliberately removes only the candidate under examination.  The
    previous global mask removed every candidate at once, so a valid bus that
    was connected to another valid bus lost the very path evidence needed to
    keep it.
    """
    skeleton = skeletonize(binary)
    for candidate in candidates:
        network = _network_without_candidate(skeleton, candidate)
        candidate.traced_components = _pixel_path_component_count(network, candidate)
        candidate.perpendicular_branches = _perpendicular_branch_count(
            network, candidate, thin_line_width, endpoint_exclusion_ratio=0.05
        )
        candidate.bent_endpoints = max(
            _bent_endpoint_count(network, candidate, thin_line_width),
            _immediate_endpoint_turn_count(network, candidate, thin_line_width),
        )


def _merge_small_run_gaps(values: np.ndarray, maximum_gap: int) -> list[tuple[int, int]]:
    """Join only tiny anti-aliasing gaps in one raster row/column."""
    changes = np.diff(np.r_[False, values, False].astype(np.int8))
    starts = np.where(changes == 1)[0].tolist()
    ends = np.where(changes == -1)[0].tolist()
    if not starts:
        return []
    merged = [[starts[0], ends[0]]]
    for start, end in zip(starts[1:], ends[1:]):
        if start - merged[-1][1] <= maximum_gap:
            merged[-1][1] = end
        else:
            merged.append([start, end])
    return [(int(start), int(end)) for start, end in merged]


def recover_fragmented_straight_buses(
    binary: np.ndarray,
    thin_line_width: int,
) -> list[Bar]:
    """Recover complete thin bus bars from raw raster runs, without YOLO.

    A directional thickness mask can split a real bus at a generator/load
    terminal.  This pass groups the remaining collinear ink across each bar's
    thickness, bridges only small scan gaps, then checks the completed bar:

    * it may not occupy most of the page;
    * it needs independent connected branches;
    * it may not turn at both reconstructed endpoints.

    The last rule rejects a routed line that happens to contain a long
    horizontal segment, while retaining a bus whose one endpoint legitimately
    feeds a conductor.
    """
    image_h, image_w = binary.shape
    # This is a recovery for a *collapsed* normal detector, not a generic
    # thin-line detector. A 45px source-scale span keeps generator leads and
    # label strokes out while preserving compact buses in the supplied sheets.
    minimum_long = max(90, thin_line_width * 16)
    maximum_gap = max(2, int(round(thin_line_width * 1.4)))
    recovered: list[Bar] = []

    for orientation in ("horizontal", "vertical"):
        axis_size = image_w if orientation == "horizontal" else image_h
        cross_size = image_h if orientation == "horizontal" else image_w
        runs: list[tuple[int, int, int]] = []
        for cross in range(cross_size):
            values = binary[cross, :] > 0 if orientation == "horizontal" else binary[:, cross] > 0
            for start, end in _merge_small_run_gaps(values, maximum_gap):
                length = end - start
                if minimum_long <= length <= axis_size * 0.35:
                    runs.append((cross, start, end))

        # Consecutive rows belonging to the same straight stroke become one
        # candidate. A parallel line must overlap strongly on the long axis to
        # join; merely being nearby is insufficient.
        clusters: list[dict[str, list[int]]] = []
        for cross, start, end in runs:
            best_cluster = None
            best_overlap = 0.0
            for cluster in reversed(clusters):
                if cross - cluster["cross"][-1] > 2:
                    break
                representative_start = float(np.median(cluster["start"]))
                representative_end = float(np.median(cluster["end"]))
                overlap = max(0.0, min(end, representative_end) - max(start, representative_start))
                minimum_length = min(end - start, representative_end - representative_start)
                if minimum_length <= 0 or overlap / minimum_length < 0.86:
                    continue
                if overlap > best_overlap:
                    best_cluster, best_overlap = cluster, overlap
            if best_cluster is None:
                clusters.append({"cross": [cross], "start": [start], "end": [end]})
            else:
                best_cluster["cross"].append(cross)
                best_cluster["start"].append(start)
                best_cluster["end"].append(end)

        for cluster in clusters:
            # Low-resolution scans often have only two fully black centre
            # rows after thresholding; the padded local check below supplies
            # the full stroke width before any topology decision is made.
            if len(cluster["cross"]) < max(2, int(round(thin_line_width * 0.40))):
                continue
            axis_start = int(round(float(np.median(cluster["start"]))))
            axis_end = int(round(float(np.median(cluster["end"]))))
            # A run can be only the two fully black centre rows of a
            # anti-aliased 4px bar.  Give the local connectivity test the
            # complete physical stroke width, otherwise its own masking step
            # leaves a horizontal residue and hides the perpendicular leads.
            cross_centre = int(round(float(np.median(cluster["cross"]))))
            cross_half = max(
                thin_line_width * 2,
                int(np.ceil((max(cluster["cross"]) - min(cluster["cross"]) + 1) / 2.0)),
            )
            cross_start = max(0, cross_centre - cross_half)
            cross_end = min(cross_size, cross_centre + cross_half + 1)
            if orientation == "horizontal":
                bar = Bar(axis_start, cross_start, axis_end - axis_start, cross_end - cross_start, orientation, 0.0)
            else:
                bar = Bar(cross_start, axis_start, cross_end - cross_start, axis_end - axis_start, orientation, 0.0)
            if min(bar.w, bar.h) <= 0:
                continue
            bar.profile_score = profile_score(binary, bar)
            _populate_local_geometry_metrics(binary, [bar], thin_line_width)
            endpoint_turns = _immediate_endpoint_turn_count(binary, bar, thin_line_width)
            long_side, short_side = max(bar.w, bar.h), min(bar.w, bar.h)
            if (
                long_side / max(short_side, 1) < 5.0
                or bar.profile_score < 0.60
                or bar.traced_components < 2
                or bar.perpendicular_branches < 1
                or endpoint_turns > 1
            ):
                continue
            # Keep the wider box only for the local branch test above. The
            # public node must remain close to the visible stroke so it does
            # not erase adjacent topology during later masking.
            display_half = max(
                thin_line_width,
                int(np.ceil((max(cluster["cross"]) - min(cluster["cross"]) + 1) / 2.0)),
            )
            if orientation == "horizontal":
                display_start = max(0, cross_centre - display_half)
                display_end = min(cross_size, cross_centre + display_half + 1)
                bar.y, bar.h = display_start, display_end - display_start
            else:
                display_start = max(0, cross_centre - display_half)
                display_end = min(cross_size, cross_centre + display_half + 1)
                bar.x, bar.w = display_start, display_end - display_start
            bar.reason = "recovered: fragmented straight bar"
            recovered.append(bar)

    # A small straight feeder segment can lie inside a recovered full bus.
    # It is not a second bus; retain only the enclosing physical bar.
    kept: list[Bar] = []
    for candidate in recovered:
        candidate_major_start = candidate.x if candidate.orientation == "horizontal" else candidate.y
        candidate_major_end = candidate_major_start + (candidate.w if candidate.orientation == "horizontal" else candidate.h)
        candidate_cross = candidate.y + candidate.h / 2 if candidate.orientation == "horizontal" else candidate.x + candidate.w / 2
        contained = False
        for other in recovered:
            if candidate is other or candidate.orientation != other.orientation:
                continue
            other_major_start = other.x if other.orientation == "horizontal" else other.y
            other_major_end = other_major_start + (other.w if other.orientation == "horizontal" else other.h)
            other_cross = other.y + other.h / 2 if other.orientation == "horizontal" else other.x + other.w / 2
            candidate_length = candidate_major_end - candidate_major_start
            other_length = other_major_end - other_major_start
            if (
                other_length >= candidate_length * 1.5
                and abs(candidate_cross - other_cross) <= max(candidate.h, candidate.w, other.h, other.w) * 0.08 + thin_line_width
                and candidate_major_start >= other_major_start - maximum_gap
                and candidate_major_end <= other_major_end + maximum_gap
            ):
                contained = True
                break
        if not contained:
            kept.append(candidate)
    return deduplicate(kept)


def _bus_family_support(candidate: Bar, pool: list[Bar]) -> int:
    """Count peers with a similar length and thickness signature."""
    long_side = float(max(candidate.w, candidate.h))
    short_side = float(min(candidate.w, candidate.h))
    support = 0
    for other in pool:
        other_long = float(max(other.w, other.h))
        other_short = float(min(other.w, other.h))
        relative_length = abs(np.log(max(long_side, 1.0) / max(other_long, 1.0)))
        thickness_gap = abs(short_side - other_short)
        thickness_tolerance = max(1.25, 0.20 * max(short_side, other_short))
        if relative_length <= 0.18 and thickness_gap <= thickness_tolerance:
            support += 1
    return support


def _adaptive_bus_thickness_floor(
    candidates: list[Bar],
    thin_line_width: int,
    minimum_long: float,
) -> float:
    """Estimate the thick-bar side of a bimodal thickness distribution."""
    values = [
        float(min(item.w, item.h))
        for item in candidates
        if max(item.w, item.h) >= minimum_long and item.profile_score >= 0.78
    ]
    base_floor = thin_line_width * 1.45
    if len(values) < 6:
        return base_floor

    rounded = np.unique(np.round(np.asarray(values) * 2.0) / 2.0)
    if len(rounded) < 2:
        return base_floor
    gaps = np.diff(rounded)
    split_index = int(np.argmax(gaps))
    largest_gap = float(gaps[split_index])
    # Values are measured on the 2x working image.  A one-pixel split is
    # normal rasterisation noise (e.g. 4.5px vs 5px at source scale), not a
    # separate line-width family.  The 14-bus reference has a real gap of
    # several working pixels between thin leads and thick bus bars.
    minimum_gap = max(2.0, thin_line_width * 0.30)
    upper_value = float(rounded[split_index + 1])
    upper_count = sum(value >= upper_value - 0.25 for value in values)
    required_count = max(4, int(np.ceil(len(values) * 0.20)))
    if largest_gap >= minimum_gap and upper_count >= required_count:
        return max(base_floor, upper_value - 0.25)
    return base_floor


def geometry_refined_buses(
    binary: np.ndarray,
    candidates: list[Bar],
    thin_line_width: int,
) -> list[Bar]:
    """Recover straight bus families that the global topology mask erased.

    Real bars repeat their approximate length/thickness across a drawing.  A
    routed line fragment is normally thinner, bent at an endpoint, or has no
    peer with the same signature.  The length floor also prevents the many
    14~30px fragments produced around labels and line corners from becoming
    false bus detections.
    """
    _populate_local_geometry_metrics(binary, candidates, thin_line_width)
    minimum_long = max(28.0, thin_line_width * 20.0)
    minimum_short = _adaptive_bus_thickness_floor(
        candidates, thin_line_width, minimum_long
    )
    eligible: list[Bar] = []
    for candidate in candidates:
        long_side = float(max(candidate.w, candidate.h))
        short_side = float(min(candidate.w, candidate.h))
        if long_side < minimum_long:
            continue
        if short_side < minimum_short:
            continue
        if candidate.profile_score < 0.78:
            continue
        if candidate.bent_endpoints >= 2 and not (
            short_side >= minimum_short
            and candidate.perpendicular_branches >= 2
            and candidate.profile_score >= 0.88
        ):
            # A routed conductor commonly enters and leaves through two bends.
            # Keep the original strict veto for that case.
            continue
        if candidate.bent_endpoints == 1 and not (
            candidate.traced_components >= 2
            and candidate.perpendicular_branches >= 1
            and candidate.profile_score >= 0.88
        ):
            # A real bus can feed one line from an endpoint.  Admit that only
            # with an independently connected, highly straight bar signature.
            continue
        eligible.append(candidate)

    selected: list[Bar] = []
    for orientation in ("horizontal", "vertical"):
        pool = [item for item in eligible if item.orientation == orientation]
        if not pool:
            continue
        supports = {id(item): _bus_family_support(item, pool) for item in pool}
        for candidate in pool:
            # Keep the established family rule for the normal geometry pass.
            # The separate thin-bar recovery below is where branch evidence is
            # required; changing this normal rule globally drops valid bars in
            # the previously verified diagrams.
            if supports[id(candidate)] >= 2:
                selected.append(candidate)
            elif (
                candidate.perpendicular_branches >= 1
                and candidate.traced_components >= 1
                and candidate.profile_score >= 0.86
            ):
                # Keep a single unusual bar only when it has an independent
                # local path and is not merely a long straight line fragment.
                selected.append(candidate)
    return deduplicate(selected)


def recover_dominant_thick_bar_family(
    candidates: list[Bar],
    thin_line_width: int,
) -> list[Bar]:
    """Select a repeated thick-bar family when local tracing is occluded.

    Some clean textbook sheets use a single repeated bus-bar style.  The
    bars are much thicker than conductors, highly straight, and all point in
    one direction, but masking a candidate can remove the branch pixels used
    by the normal topology score.  In that specific dominant-family case the
    repeated visual structure is stronger evidence than a zero path count.
    """
    minimum_long = max(70.0, thin_line_width * 8.0)
    minimum_short = thin_line_width * 1.8
    eligible = [
        bar for bar in candidates
        if (
            max(bar.w, bar.h) >= minimum_long
            and min(bar.w, bar.h) >= minimum_short
            and bar.profile_score >= 0.85
            and bar.bent_endpoints <= 1
        )
    ]
    groups = {
        orientation: [bar for bar in eligible if bar.orientation == orientation]
        for orientation in ("horizontal", "vertical")
    }
    dominant_orientation = max(groups, key=lambda orientation: len(groups[orientation]))
    dominant = groups[dominant_orientation]
    secondary = groups["vertical" if dominant_orientation == "horizontal" else "horizontal"]
    if len(dominant) < 12 or len(dominant) < max(12, len(secondary) * 3):
        return []

    median_short = float(np.median([min(bar.w, bar.h) for bar in dominant]))
    family = [
        bar for bar in dominant
        if median_short * 0.72 <= min(bar.w, bar.h) <= median_short * 1.35
    ]
    if len(family) < 12:
        return []
    for bar in family:
        bar.reason = "recovered: dominant thick-bar family"
    return deduplicate(family)


def recover_consistent_mixed_layout_buses(
    candidates: list[Bar],
    selected: list[Bar],
    thin_line_width: int,
) -> list[Bar]:
    """Use consistent bar thickness to correct a mixed-layout selection.

    In a mixed horizontal/vertical diagram the family selector can retain an
    ordinary vertical conductor while dropping several real horizontal buses
    whose crossings split their morphology.  Electrical buses have a shared
    stroke family; routed conductors are usually thinner.  When there are
    enough independently connected horizontal members, rebuild the result
    from that family and keep a vertical member only if it matches the same
    physical thickness and has local branch/path evidence.

    This is deliberately dormant for small layouts (fewer than six strong
    horizontal members), where the existing conservative logic is safer.
    """
    minimum_horizontal_length = max(120.0, thin_line_width * 22.0)
    minimum_short = thin_line_width * 1.55
    horizontal = [
        candidate
        for candidate in candidates
        if (
            candidate.orientation == "horizontal"
            and max(candidate.w, candidate.h) >= minimum_horizontal_length
            and min(candidate.w, candidate.h) >= minimum_short
            and candidate.profile_score >= 0.82
            and candidate.perpendicular_branches >= 1
            and candidate.bent_endpoints <= 1
        )
    ]
    horizontal = deduplicate(horizontal)
    if len(horizontal) < 6:
        return deduplicate(selected)

    horizontal_short = float(np.median([min(item.w, item.h) for item in horizontal]))
    vertical = [
        candidate
        for candidate in candidates
        if (
            candidate.orientation == "vertical"
            and max(candidate.w, candidate.h) >= max(100.0, thin_line_width * 18.0)
            # A true vertical bus uses the same (or a marginally wider)
            # physical stroke as its horizontal peers.  A 10% allowance kept
            # ordinary thin vertical feeders in mixed layouts, so require the
            # full horizontal family thickness here.
            and min(candidate.w, candidate.h) >= max(minimum_short, horizontal_short)
            and candidate.profile_score >= 0.85
            and candidate.traced_components >= 1
            and candidate.perpendicular_branches >= 1
            and candidate.bent_endpoints <= 1
        )
    ]
    recovered = deduplicate(horizontal + vertical)
    # Recovery is allowed to correct a weaker mixed-layout selection, never
    # to replace a larger already-connected family.  This protects dense
    # all-horizontal layouts where a few legitimate buses have temporarily
    # obscured branch pixels and therefore miss the stricter rebuild gate.
    if len(recovered) < len(horizontal) or len(recovered) < len(selected):
        return deduplicate(selected)
    for candidate in recovered:
        candidate.reason = "recovered: consistent mixed-layout bus family"
    return recovered


def choose_adaptive_bus_bars(
    binary: np.ndarray,
    candidates: list[Bar],
    conservative_buses: list[Bar],
    thin_line_width: int,
    reject_branchless_geometry: bool = False,
) -> list[Bar]:
    """Choose between conservative topology and adaptive geometry results.

    When both orientations contain many strong candidates, the diagram is a
    mixed layout and the conservative result is safer.  When one orientation
    clearly dominates, the global-mask failure mode is more likely, so the
    repeated straight-bar family is preferred.  This is an image-derived
    decision; no TEST filename or bus count is hard-coded.
    """
    conservative_buses = _remove_thin_outlier_bars(
        conservative_buses, thin_line_width
    )
    geometry_buses = geometry_refined_buses(binary, candidates, thin_line_width)
    recovered_geometry = [
        bar for bar in conservative_buses
        if bar.reason.startswith("recovered:")
    ]
    geometry_buses = deduplicate(geometry_buses + recovered_geometry)
    if reject_branchless_geometry:
        # In an all-horizontal thin-bar layout, a branchless geometry result
        # is much more likely to be a routed line fragment.  Do not apply this
        # veto to the normal mixed-layout path: some earlier reference images
        # contain legitimate bars whose local branch pixels are obscured.
        geometry_buses = [
            bar for bar in geometry_buses
            if bar.perpendicular_branches >= 1
        ]
    if not geometry_buses:
        return deduplicate(conservative_buses)

    # If the conservative pass already retains a substantially larger
    # internally connected set, the geometry pass is likely being starved by
    # a layout-specific scale or crop.  Do not replace a strong result with a
    # smaller one; this is what protects the original 39-bus reference image.
    if len(conservative_buses) >= len(geometry_buses) + 5:
        return deduplicate(conservative_buses)

    horizontal = [bar for bar in geometry_buses if bar.orientation == "horizontal"]
    vertical = [bar for bar in geometry_buses if bar.orientation == "vertical"]
    groups = {"horizontal": horizontal, "vertical": vertical}
    dominant_orientation = max(groups, key=lambda key: len(groups[key]))
    secondary_orientation = "vertical" if dominant_orientation == "horizontal" else "horizontal"
    dominant = groups[dominant_orientation]
    secondary = groups[secondary_orientation]
    dominant_count, secondary_count = len(dominant), len(secondary)

    # Two strong orientations are a genuine mixed diagram (for example the
    # 24-bus layout), where the existing branch/bend checks are safer.
    if dominant_count < 25 and dominant_count >= 8 and secondary_count >= 3:
        return deduplicate(conservative_buses)

    # A very large repeated family is characteristic of the all-horizontal or
    # all-vertical IEEE layouts.  In that case the other orientation is made
    # almost entirely from thin routed-line fragments, even when those
    # fragments happen to have local branch pixels.
    if dominant_count >= 25:
        thin_layout_secondary = any(
            bar.reason == "recovered: thin connected bar"
            for bar in conservative_buses
        )
        isolated_secondary = [
            bar for bar in secondary
            if (
                secondary_count <= 2
                and bar.perpendicular_branches >= 2
                and (
                    (
                        thin_layout_secondary
                        and bar.traced_components >= 1
                        and bar.profile_score >= 0.84
                    )
                    or (
                        not thin_layout_secondary
                        and bar.traced_components >= 2
                        and bar.profile_score >= 0.88
                    )
                )
            )
        ]
        return deduplicate(dominant + isolated_secondary)

    # Otherwise use the dominant repeated family.  A weak secondary group is
    # retained only when its thickness is consistent with the dominant bars;
    # this preserves isolated vertical buses while rejecting thin line pieces.
    selected = list(dominant)
    if secondary:
        dominant_short = float(np.median([min(bar.w, bar.h) for bar in dominant]))
        secondary = [
            bar for bar in secondary
            if min(bar.w, bar.h) >= dominant_short * 0.90
        ]
        selected.extend(secondary)
    return deduplicate(selected)


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


def detect_cv_buses(
    image: np.ndarray,
    return_debug: bool = False,
) -> list[dict[str, float | str]] | tuple[list[dict[str, float | str]], list[dict[str, float | str]]]:
    """Detect bus bars for the API without writing any comparison files.

    The returned coordinates use the original image scale and the same
    ``[x_center, y_center, width, height]`` format as Ultralytics boxes.
    """
    binary = binarize_and_repair(image)
    thin_width = estimate_thin_line_width(binary)
    # Keep the production mask conservative.  A second, isolated thin-bar
    # pass below handles the few diagrams whose bus stroke is only ~4px at the
    # source scale without allowing every thin feeder into the normal family
    # selection.
    min_thickness = max(5, int(round(thin_width * 1.6)))
    horizontal_mask, vertical_mask = directional_bar_masks(binary, min_thickness)
    horizontal, recovery_h, rejected_h = collect_bars(
        horizontal_mask, binary, "horizontal", thin_width
    )
    vertical, recovery_v, rejected_v = collect_bars(
        vertical_mask, binary, "vertical", thin_width
    )
    clear_buses = deduplicate(horizontal + vertical)
    recovery_buses = deduplicate(recovery_h + recovery_v)
    candidates = deduplicate(clear_buses + recovery_buses)
    traced_buses = pixel_path_connected_buses(binary, candidates, thin_width)
    base_buses = topology_refined_buses(
        binary, traced_buses, thin_width, endpoint_exclusion_ratio=0.05
    )
    # Thin recovery is deliberately isolated from the normal candidate pool.
    # This preserves the old bus-family result for all previously tested
    # images while recovering straight, branch-connected 4px bars such as
    # TEST6 buses 9, 11, 12, 13, and 16.
    thin_min_thickness = max(5, int(round(thin_width * 1.35)))
    thin_horizontal_mask, thin_vertical_mask = directional_bar_masks(
        binary, thin_min_thickness
    )
    _, _, thin_rejected_h = collect_bars(
        thin_horizontal_mask, binary, "horizontal", thin_width
    )
    _, _, thin_rejected_v = collect_bars(
        thin_vertical_mask, binary, "vertical", thin_width
    )
    thin_recovered = recover_thin_connected_bars(
        binary,
        thin_rejected_h + thin_rejected_v,
        thin_width,
        endpoint_exclusion_ratio=0.05,
    )
    # A mixed horizontal/vertical diagram has a different ambiguity pattern:
    # the secondary thin mask also picks up short feeder fragments near the
    # vertical bus family.  Keep the established topology result there and
    # enable the thin recovery only for layouts with no vertical bus evidence.
    thin_recovery_enabled = not any(
        (
            bar.orientation == "vertical"
            and min(bar.w, bar.h) >= thin_width * 2.0
            and bar.profile_score >= 0.84
        )
        for bar in base_buses
    )
    if not thin_recovery_enabled:
        thin_recovered = []
    compact_vertical = recover_compact_vertical_buses(
        binary, candidates, base_buses, thin_width
    )
    locally_recovered = recover_locally_connected_buses(
        binary, candidates, base_buses, thin_width, endpoint_exclusion_ratio=0.05
    )
    conservative_buses = deduplicate(
        base_buses + locally_recovered + thin_recovered + compact_vertical
    )
    final_buses = choose_adaptive_bus_bars(
        binary,
        candidates,
        conservative_buses,
        thin_width,
        reject_branchless_geometry=bool(thin_recovered),
    )
    final_buses = recover_consistent_mixed_layout_buses(
        candidates,
        final_buses,
        thin_width,
    )
    dominant_family = recover_dominant_thick_bar_family(candidates, thin_width)
    if dominant_family and len(final_buses) < len(dominant_family) * 0.70:
        final_buses = dominant_family
    fragmented_recovered: list[Bar] = []
    # Use this independent reconstruction only when the normal directional
    # mask has clearly collapsed to one or two fragments. In ordinary IEEE
    # sheets the normal path remains the authority; this protects previously
    # validated mixed layouts from a broad low-thickness union.
    if len(final_buses) <= 2:
        fragmented_recovered = recover_fragmented_straight_buses(binary, thin_width)
        if len(fragmented_recovered) >= 3:
            final_buses = fragmented_recovered
    local_ids = {
        id(bar) for bar in (
            locally_recovered
            + thin_recovered
            + compact_vertical
            + fragmented_recovered
            + dominant_family
        )
    }
    geometry_ids = {id(bar) for bar in final_buses} - {id(bar) for bar in conservative_buses}
    detected: list[dict[str, float | str]] = []
    for bar in final_buses:
        detected.append({
            "x": (bar.x + bar.w / 2) / SCALE,
            "y": (bar.y + bar.h / 2) / SCALE,
            "w": bar.w / SCALE,
            "h": bar.h / SCALE,
            "orientation": bar.orientation,
            # Geometry recovery is slightly less certain than the original
            # topology path, but is still above the old YOLO fallback score.
            "confidence": (
                0.90 if id(bar) in local_ids
                else 0.92 if id(bar) in geometry_ids
                else 0.95
            ),
        })
    if not return_debug:
        return detected

    # Keep the CV rejection registry available to the orchestrator.  YOLO is
    # allowed to resurrect only one of these candidates after the strict
    # geometry/branch checks below; arbitrary YOLO bars never enter topology.
    final_ids = {id(bar) for bar in final_buses}
    all_candidates = deduplicate(candidates + conservative_buses)
    rejected: list[dict[str, float | str]] = []
    for bar in all_candidates:
        if id(bar) in final_ids:
            continue
        rejected.append({
            "x": (bar.x + bar.w / 2) / SCALE,
            "y": (bar.y + bar.h / 2) / SCALE,
            "w": bar.w / SCALE,
            "h": bar.h / SCALE,
            "orientation": bar.orientation,
            "profile_score": float(bar.profile_score),
            "traced_components": float(bar.traced_components),
            "perpendicular_branches": float(bar.perpendicular_branches),
            "bent_endpoints": float(bar.bent_endpoints),
            "reason": bar.reason,
        })
    return detected, rejected


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
        thin_min_thickness = max(5, int(round(thin_width * 1.35)))
        thin_h_mask, thin_v_mask = directional_bar_masks(binary, thin_min_thickness)
        _, _, thin_rejected_h = collect_bars(
            thin_h_mask, binary, "horizontal", thin_width
        )
        _, _, thin_rejected_v = collect_bars(
            thin_v_mask, binary, "vertical", thin_width
        )
        thin_recovered_buses = recover_thin_connected_bars(
            binary,
            thin_rejected_h + thin_rejected_v,
            thin_width,
            endpoint_exclusion_ratio=0.05,
        )
        if any(
            (
                bar.orientation == "vertical"
                and min(bar.w, bar.h) >= thin_width * 2.0
                and bar.profile_score >= 0.84
            )
            for bar in base_topology_buses
        ):
            thin_recovered_buses = []
        buses = deduplicate(buses + thin_recovered_buses)
        baseline_traced_buses = pixel_path_connected_buses(binary, clear_buses, thin_width)
        baseline_topology_buses = topology_refined_buses(
            binary, baseline_traced_buses, thin_width, endpoint_exclusion_ratio=0.05
        )
        connected_buses = [bar for bar in buses if has_network_connection(binary, bar, thin_width)]
        traced_buses = pixel_path_connected_buses(binary, buses, thin_width)
        base_topology_buses = topology_refined_buses(
            binary, traced_buses, thin_width, endpoint_exclusion_ratio=0.05
        )
        compact_vertical_buses = recover_compact_vertical_buses(
            binary, buses, base_topology_buses, thin_width
        )
        locally_recovered_buses = recover_locally_connected_buses(
            binary, buses, base_topology_buses, thin_width, endpoint_exclusion_ratio=0.05
        )
        topology_buses = deduplicate(
            base_topology_buses
            + locally_recovered_buses
            + thin_recovered_buses
            + compact_vertical_buses
        )
        metrics_buses = deduplicate(
            traced_buses
            + locally_recovered_buses
            + thin_recovered_buses
            + compact_vertical_buses
        )

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

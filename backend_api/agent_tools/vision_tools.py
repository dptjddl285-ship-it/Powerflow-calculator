"""Review Tool adapters around the existing PowerLens Vision pipeline.

No detector or line-tracing algorithm is duplicated here. Both tools crop the
stored source image, call the existing adaptive analyzer, map its result back
to original-image coordinates, and emit preview-only graph operations.
"""

from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import math
from typing import Any, Callable, Mapping
import uuid

import cv2
import numpy as np

from review.graph_document import (
    CenterBBox,
    GraphDocument,
    GraphEdge,
    GraphNode,
    PixelPoint,
    Port,
    ReviewIssue,
    ReviewState,
)
from review.patches import (
    PatchOperation,
    PatchPreview,
    PatchStatus,
    RoiBounds,
)
from review.store import AnalysisAsset


Analyzer = Callable[[bytes], Mapping[str, Any]]


class ReviewToolUnavailableError(Exception):
    pass


class ReviewToolInputError(Exception):
    pass


class ReviewToolRuntime:
    def __init__(self) -> None:
        self._analyzer: Analyzer | None = None

    def configure(self, analyzer: Analyzer) -> None:
        self._analyzer = analyzer

    def analyze(self, image_bytes: bytes) -> Mapping[str, Any]:
        if self._analyzer is None:
            raise ReviewToolUnavailableError("review Vision analyzer is not configured")
        return self._analyzer(image_bytes)


runtime = ReviewToolRuntime()


def configure_review_tools(analyzer: Analyzer) -> None:
    runtime.configure(analyzer)


def _stable_id(prefix: str, document_id: str, identity: str) -> str:
    value = uuid.uuid5(uuid.NAMESPACE_URL, f"powerlens:{document_id}:{identity}")
    return f"{prefix}_{value.hex[:16]}"


def _decode_image(image_bytes: bytes) -> np.ndarray:
    image = cv2.imdecode(np.frombuffer(image_bytes, np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ReviewToolInputError("stored source image could not be decoded")
    return image


def _encode_png(image: np.ndarray) -> bytes:
    ok, encoded = cv2.imencode(".png", image)
    if not ok:
        raise ReviewToolInputError("ROI image could not be encoded")
    return encoded.tobytes()


def _node_rect(node: GraphNode) -> tuple[float, float, float, float]:
    box = node.bbox
    return (
        box.center_x - box.width / 2.0,
        box.center_y - box.height / 2.0,
        box.center_x + box.width / 2.0,
        box.center_y + box.height / 2.0,
    )


def _candidate_rect(raw_bbox: list[float]) -> tuple[float, float, float, float]:
    cx, cy, width, height = (float(value) for value in raw_bbox)
    return (
        cx - width / 2.0,
        cy - height / 2.0,
        cx + width / 2.0,
        cy + height / 2.0,
    )


def _iou(first: tuple[float, float, float, float], second: tuple[float, float, float, float]) -> float:
    x1 = max(first[0], second[0])
    y1 = max(first[1], second[1])
    x2 = min(first[2], second[2])
    y2 = min(first[3], second[3])
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    if intersection <= 0.0:
        return 0.0
    first_area = max(0.0, first[2] - first[0]) * max(0.0, first[3] - first[1])
    second_area = max(0.0, second[2] - second[0]) * max(0.0, second[3] - second[1])
    return intersection / max(first_area + second_area - intersection, 1e-6)


def _intersection_over_smaller(
    first: tuple[float, float, float, float],
    second: tuple[float, float, float, float],
) -> float:
    x1 = max(first[0], second[0])
    y1 = max(first[1], second[1])
    x2 = min(first[2], second[2])
    y2 = min(first[3], second[3])
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    if intersection <= 0.0:
        return 0.0
    first_area = max(0.0, first[2] - first[0]) * max(0.0, first[3] - first[1])
    second_area = max(0.0, second[2] - second[0]) * max(0.0, second[3] - second[1])
    return intersection / max(min(first_area, second_area), 1e-6)


def _issue_nodes(document: GraphDocument, issue: ReviewIssue) -> list[GraphNode]:
    wanted = set(issue.component_ids)
    nodes = [node for node in document.nodes if node.internal_id in wanted]
    if not nodes:
        raise ReviewToolInputError(
            "issue has no GraphDocument component bbox; a user-selected ROI is required"
        )
    return nodes


def _roi_bounds(
    document: GraphDocument,
    issue: ReviewIssue,
    image: np.ndarray,
    *,
    port_context: bool,
) -> RoiBounds:
    height, width = image.shape[:2]
    if issue.roi is not None:
        left = max(0, int(math.floor(issue.roi.x_min)))
        top = max(0, int(math.floor(issue.roi.y_min)))
        right = min(width, int(math.ceil(issue.roi.x_max)))
        bottom = min(height, int(math.ceil(issue.roi.y_max)))
        if right <= left or bottom <= top:
            raise ReviewToolInputError("user-selected ROI is outside the source image")
        return RoiBounds(x_min=left, y_min=top, x_max=right, y_max=bottom)
    focus = _issue_nodes(document, issue)
    context_nodes = list(focus)
    focus_ids = {node.internal_id for node in focus}
    path_points: list[tuple[float, float]] = []

    if port_context:
        # Reuse nearby graph context so the existing port-aware tracer sees a
        # possible opposite Bus/device instead of an isolated symbol crop.
        focus_center_x = sum(node.bbox.center_x for node in focus) / len(focus)
        focus_center_y = sum(node.bbox.center_y for node in focus) / len(focus)
        nearest = sorted(
            (node for node in document.nodes if node.internal_id not in focus_ids),
            key=lambda node: math.hypot(
                node.bbox.center_x - focus_center_x,
                node.bbox.center_y - focus_center_y,
            ),
        )[:4]
        context_nodes.extend(nearest)
        for edge in document.edges:
            if edge.source_node_id in focus_ids or edge.target_node_id in focus_ids:
                path_points.extend((point.x, point.y) for point in edge.path)

    rects = [_node_rect(node) for node in context_nodes]
    x_min = min(rect[0] for rect in rects)
    y_min = min(rect[1] for rect in rects)
    x_max = max(rect[2] for rect in rects)
    y_max = max(rect[3] for rect in rects)
    if path_points:
        x_min = min(x_min, *(point[0] for point in path_points))
        y_min = min(y_min, *(point[1] for point in path_points))
        x_max = max(x_max, *(point[0] for point in path_points))
        y_max = max(y_max, *(point[1] for point in path_points))

    span = max(x_max - x_min, y_max - y_min)
    margin = max(48.0, span * (0.55 if port_context else 0.80))
    minimum_side = 420.0 if port_context else 280.0
    center_x = (x_min + x_max) / 2.0
    center_y = (y_min + y_max) / 2.0
    half_width = max((x_max - x_min) / 2.0 + margin, minimum_side / 2.0)
    half_height = max((y_max - y_min) / 2.0 + margin, minimum_side / 2.0)
    left = max(0, int(math.floor(center_x - half_width)))
    top = max(0, int(math.floor(center_y - half_height)))
    right = min(width, int(math.ceil(center_x + half_width)))
    bottom = min(height, int(math.ceil(center_y + half_height)))
    if right <= left or bottom <= top:
        raise ReviewToolInputError("issue ROI is outside the source image")
    return RoiBounds(x_min=left, y_min=top, x_max=right, y_max=bottom)


def _shift_result_to_original(
    result: Mapping[str, Any],
    roi: RoiBounds,
) -> dict[str, Any]:
    shifted = deepcopy(dict(result))
    for node in shifted.get("nodes", []):
        bbox = node.get("bbox")
        if isinstance(bbox, list) and len(bbox) == 4:
            bbox[0] = float(bbox[0]) + roi.x_min
            bbox[1] = float(bbox[1]) + roi.y_min
    for line in shifted.get("lines", []):
        line["path"] = [
            [float(point[0]) + roi.x_min, float(point[1]) + roi.y_min]
            for point in line.get("path", [])
            if isinstance(point, (list, tuple)) and len(point) == 2
        ]
    return shifted


def _match_candidates(
    document: GraphDocument,
    raw_nodes: list[dict[str, Any]],
) -> tuple[dict[str, str], list[dict[str, Any]]]:
    mapping: dict[str, str] = {}
    unmatched: list[dict[str, Any]] = []
    used: set[str] = set()
    for raw in raw_nodes:
        source_id = str(raw.get("id"))
        class_name = str(raw.get("class", "")).lower()
        bbox = [float(value) for value in raw.get("bbox", [])]
        if len(bbox) != 4:
            continue
        candidates: list[tuple[float, float, GraphNode]] = []
        for node in document.nodes:
            if node.type != class_name:
                continue
            overlap = _iou(_candidate_rect(bbox), _node_rect(node))
            distance = math.hypot(
                bbox[0] - node.bbox.center_x,
                bbox[1] - node.bbox.center_y,
            )
            tolerance = max(
                18.0,
                0.40 * max(bbox[2], bbox[3], node.bbox.width, node.bbox.height),
            )
            if overlap >= 0.20 or distance <= tolerance:
                candidates.append((overlap, -distance, node))
        if candidates:
            # Overlapping scan tiles can detect the same existing object more
            # than once. Prefer an unused node when several nearby nodes are
            # plausible, but never turn a repeated detection into a missing
            # object merely because its existing node was matched already.
            available = [
                candidate for candidate in candidates
                if candidate[2].internal_id not in used
            ]
            best = max(
                available or candidates,
                key=lambda item: (item[0], item[1]),
            )[2]
            mapping[source_id] = best.internal_id
            used.add(best.internal_id)
        else:
            unmatched.append(raw)
    return mapping, unmatched


def _split_cross_class_conflicts(
    document: GraphDocument,
    candidates: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Do not call an occupied region a missing object.

    A class disagreement is useful review evidence, but adding the second node
    would create two component types at the same location. Keep such records
    out of the applicable patch and report them separately as class conflicts.
    The thresholds are normalized by box area so they are not image-specific.
    """
    missing: list[dict[str, Any]] = []
    conflicts: list[dict[str, Any]] = []
    for raw in candidates:
        bbox = [float(value) for value in raw.get("bbox", [])]
        if len(bbox) != 4:
            continue
        candidate_class = str(raw.get("class", "")).lower()
        candidate_rect = _candidate_rect(bbox)
        best: tuple[float, float, GraphNode] | None = None
        for node in document.nodes:
            if node.type == candidate_class:
                continue
            node_rect = _node_rect(node)
            overlap = _iou(candidate_rect, node_rect)
            containment = _intersection_over_smaller(candidate_rect, node_rect)
            if overlap < 0.35 and containment < 0.70:
                continue
            score = max(overlap, containment * 0.75)
            if best is None or score > best[0]:
                best = (score, containment, node)
        if best is None:
            missing.append(raw)
            continue
        overlap_score, containment, node = best
        conflicts.append({
            "candidate_class": candidate_class,
            "candidate_confidence": float(raw.get("confidence", 0.0)),
            "candidate_bbox": bbox,
            "existing_node_id": node.internal_id,
            "existing_class": node.type,
            "overlap_score": float(overlap_score),
            "intersection_over_smaller": float(containment),
        })
    return missing, conflicts


def _new_node(
    document: GraphDocument,
    issue: ReviewIssue,
    tool_name: str,
    raw: Mapping[str, Any],
) -> GraphNode:
    bbox = [float(value) for value in raw["bbox"]]
    identity = (
        f"{issue.issue_id}:{tool_name}:{raw.get('class')}:"
        f"{bbox[0]:.1f}:{bbox[1]:.1f}:{bbox[2]:.1f}:{bbox[3]:.1f}"
    )
    internal_id = _stable_id("node", document.document_id, identity)
    box = CenterBBox(
        center_x=bbox[0],
        center_y=bbox[1],
        width=bbox[2],
        height=bbox[3],
    )
    parameters: dict[str, Any] = {}
    if tool_name == "missing_object_scan":
        parameters["review_candidate"] = {
            "kind": "missing_object",
            "confidence": max(
                0.0,
                min(1.0, float(raw.get("confidence", 0.0))),
            ),
            "evidence": [
                "기존 동일 종류 객체와 위치가 일치하지 않음",
                "겹침 타일의 반복 검출을 병합함",
                f"검출 출처: {raw.get('source', 'existing_pipeline')}",
            ],
        }
    return GraphNode(
        internal_id=internal_id,
        source_id=f"{tool_name}:{raw.get('id')}",
        type=str(raw["class"]).lower(),
        bbox=box,
        original_bbox=box.model_copy(deep=True),
        confidence=max(0.0, min(1.0, float(raw.get("confidence", 0.0)))),
        source=f"{tool_name}:{raw.get('source', 'existing_pipeline')}",
        review_state=ReviewState.NEEDS_REVIEW,
        parameters=parameters,
    )


def _port_side(raw_port: Any, fallback: str = "boundary") -> str:
    if isinstance(raw_port, Mapping):
        return str(raw_port.get("side") or fallback)
    if isinstance(raw_port, str) and raw_port:
        return raw_port
    return fallback


def _optional_float(raw_port: Any, key: str) -> float | None:
    if isinstance(raw_port, Mapping) and raw_port.get(key) is not None:
        return float(raw_port[key])
    return None


def _edge_operation(
    document: GraphDocument,
    issue: ReviewIssue,
    tool_name: str,
    raw_line: Mapping[str, Any],
    source_node_id: str,
    target_node_id: str,
) -> PatchOperation | None:
    path_values = raw_line.get("path") or []
    if len(path_values) < 2 or source_node_id == target_node_id:
        return None
    path = [PixelPoint(x=float(point[0]), y=float(point[1])) for point in path_values]
    identity = (
        f"{issue.issue_id}:{tool_name}:{source_node_id}:{target_node_id}:"
        f"{path[0].x:.1f}:{path[0].y:.1f}:{path[-1].x:.1f}:{path[-1].y:.1f}"
    )
    edge_id = _stable_id("edge", document.document_id, identity)
    source_port_id = _stable_id("port", document.document_id, f"{identity}:source")
    target_port_id = _stable_id("port", document.document_id, f"{identity}:target")
    raw_source_port = raw_line.get("source_port")
    raw_target_port = raw_line.get("target_port")
    ports = [
        Port(
            port_id=source_port_id,
            node_id=source_node_id,
            side=_port_side(raw_source_port),
            point=path[0],
            score=_optional_float(raw_source_port, "score"),
            distance=_optional_float(raw_source_port, "distance"),
        ),
        Port(
            port_id=target_port_id,
            node_id=target_node_id,
            side=_port_side(raw_target_port),
            point=path[-1],
            score=_optional_float(raw_target_port, "score"),
            distance=_optional_float(raw_target_port, "distance"),
        ),
    ]
    edge = GraphEdge(
        internal_id=edge_id,
        source_id=f"{tool_name}:{raw_line.get('line_id', edge_id)}",
        source_node_id=source_node_id,
        target_node_id=target_node_id,
        source_port_id=source_port_id,
        target_port_id=target_port_id,
        path=path,
        trace_method=str(raw_line.get("trace_method", "existing_port_aware_pipeline")),
    )
    return PatchOperation(operation="add_edge", edge=edge, ports=ports)


class ReviewVisionToolRunner:
    SUPPORTED_TOOLS = {
        "roi_reanalysis",
        "port_aware_retry",
        "missing_object_scan",
    }

    @staticmethod
    def _scan_tiles(image: np.ndarray) -> list[RoiBounds]:
        height, width = image.shape[:2]
        if width <= 420 and height <= 420:
            return [RoiBounds(x_min=0, y_min=0, x_max=width, y_max=height)]

        tile_width = min(width, max(360, int(round(width * 0.58))))
        tile_height = min(height, max(360, int(round(height * 0.58))))
        overlap = max(48, int(round(min(tile_width, tile_height) * 0.16)))

        def starts(length: int, tile: int) -> list[int]:
            if tile >= length:
                return [0]
            values = list(range(0, max(1, length - tile + 1), max(1, tile - overlap)))
            final = length - tile
            if values[-1] != final:
                values.append(final)
            return values

        return [
            RoiBounds(
                x_min=x,
                y_min=y,
                x_max=x + tile_width,
                y_max=y + tile_height,
            )
            for y in starts(height, tile_height)
            for x in starts(width, tile_width)
        ]

    @staticmethod
    def _deduplicate_unmatched(
        candidates: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        selected: list[dict[str, Any]] = []
        ordered = sorted(
            candidates,
            key=lambda item: float(item.get("confidence", 0.0)),
            reverse=True,
        )
        for raw in ordered:
            bbox = [float(value) for value in raw.get("bbox", [])]
            if len(bbox) != 4:
                continue
            class_name = str(raw.get("class", "")).lower()
            if class_name not in {"bus", "generator", "load", "transformer"}:
                continue
            duplicate = False
            for kept in selected:
                if str(kept.get("class", "")).lower() != class_name:
                    continue
                kept_bbox = [float(value) for value in kept["bbox"]]
                overlap = _iou(_candidate_rect(bbox), _candidate_rect(kept_bbox))
                distance = math.hypot(bbox[0] - kept_bbox[0], bbox[1] - kept_bbox[1])
                tolerance = 0.30 * max(bbox[2], bbox[3], kept_bbox[2], kept_bbox[3])
                if overlap >= 0.30 or distance <= max(12.0, tolerance):
                    duplicate = True
                    break
            if not duplicate:
                selected.append(raw)
        return selected

    def create_missing_object_preview(
        self,
        *,
        document: GraphDocument,
        issue: ReviewIssue,
        asset: AnalysisAsset,
    ) -> PatchPreview:
        image = _decode_image(asset.image_bytes)
        height, width = image.shape[:2]
        raw_candidates: list[dict[str, Any]] = []
        tiles = self._scan_tiles(image)
        for tile_index, roi in enumerate(tiles):
            crop = image[roi.y_min:roi.y_max, roi.x_min:roi.x_max]
            local_result = runtime.analyze(_encode_png(crop))
            shifted = _shift_result_to_original(local_result, roi)
            for raw in shifted.get("nodes", []):
                item = dict(raw)
                item["id"] = f"tile_{tile_index}:{item.get('id')}"
                raw_candidates.append(item)

        _, unmatched = _match_candidates(document, raw_candidates)
        missing, class_conflicts = _split_cross_class_conflicts(
            document,
            unmatched,
        )
        candidates = self._deduplicate_unmatched(missing)[:24]
        operations = [
            PatchOperation(
                operation="add_node",
                node=_new_node(document, issue, "missing_object_scan", raw),
            )
            for raw in candidates
        ]
        status = PatchStatus.PENDING if operations else PatchStatus.NO_CHANGE
        patch_identity = (
            f"{issue.issue_id}:missing_object_scan:{document.revision}:{uuid.uuid4().hex}"
        )
        return PatchPreview(
            patch_id=_stable_id("patch", document.document_id, patch_identity),
            document_id=document.document_id,
            base_revision=document.revision,
            issue_id=issue.issue_id,
            tool_name="missing_object_scan",
            status=status,
            roi=RoiBounds(x_min=0, y_min=0, x_max=width, y_max=height),
            summary=(
                f"Missing-object scan found {len(operations)} candidate(s)"
                if operations
                else "Missing-object scan found no new object candidate"
            ),
            evidence=[
                "existing adaptive Vision pipeline rerun on overlapping image tiles",
                "detections overlapping existing GraphDocument nodes removed",
                "class-aware candidate deduplication applied",
                "no line operation generated",
            ],
            operations=operations,
            analysis_snapshot={
                "tile_count": len(tiles),
                "raw_detected_nodes": len(raw_candidates),
                "unmatched_nodes": len(unmatched),
                "class_conflict_count": len(class_conflicts),
                "class_conflicts": class_conflicts,
                "proposed_node_additions": len(operations),
            },
            created_at=datetime.now(timezone.utc),
        )

    def create_preview(
        self,
        *,
        tool_name: str,
        document: GraphDocument,
        issue: ReviewIssue,
        asset: AnalysisAsset,
    ) -> PatchPreview:
        if tool_name not in self.SUPPORTED_TOOLS or tool_name == "missing_object_scan":
            raise ReviewToolInputError(f"unsupported review tool: {tool_name}")
        image = _decode_image(asset.image_bytes)
        port_context = tool_name == "port_aware_retry"
        roi = _roi_bounds(document, issue, image, port_context=port_context)
        crop = image[roi.y_min:roi.y_max, roi.x_min:roi.x_max]
        local_result = runtime.analyze(_encode_png(crop))
        result = _shift_result_to_original(local_result, roi)
        raw_nodes = [dict(item) for item in result.get("nodes", [])]
        mapping, unmatched = _match_candidates(document, raw_nodes)
        operations: list[PatchOperation] = []
        new_node_ids: set[str] = set()

        if tool_name == "roi_reanalysis":
            for raw in unmatched[:8]:
                class_name = str(raw.get("class", "")).lower()
                if class_name not in {"bus", "generator", "load", "transformer"}:
                    continue
                node = _new_node(document, issue, tool_name, raw)
                mapping[str(raw.get("id"))] = node.internal_id
                new_node_ids.add(node.internal_id)
                operations.append(PatchOperation(operation="add_node", node=node))

        existing_pairs = {
            frozenset((edge.source_node_id, edge.target_node_id))
            for edge in document.edges
        }
        proposed_pairs: set[frozenset[str]] = set()
        issue_components = set(issue.component_ids)
        for raw_line in result.get("lines", []):
            endpoints = list(raw_line.get("connected_to") or [])
            if len(endpoints) != 2:
                continue
            source_node_id = mapping.get(str(endpoints[0]))
            target_node_id = mapping.get(str(endpoints[1]))
            if source_node_id is None or target_node_id is None:
                continue
            pair = frozenset((source_node_id, target_node_id))
            if pair in existing_pairs or pair in proposed_pairs:
                continue
            if tool_name == "port_aware_retry" and not (
                pair & issue_components
            ):
                continue
            if tool_name == "roi_reanalysis" and not (
                pair & issue_components or pair & new_node_ids
            ):
                continue
            operation = _edge_operation(
                document,
                issue,
                tool_name,
                raw_line,
                source_node_id,
                target_node_id,
            )
            if operation is not None:
                operations.append(operation)
                proposed_pairs.add(pair)

        status = PatchStatus.PENDING if operations else PatchStatus.NO_CHANGE
        node_additions = sum(item.operation == "add_node" for item in operations)
        edge_additions = sum(item.operation == "add_edge" for item in operations)
        summary = (
            f"{tool_name} found {node_additions} node and {edge_additions} edge candidate(s)"
            if operations
            else f"{tool_name} found no graph change candidate"
        )
        patch_identity = f"{issue.issue_id}:{tool_name}:{document.revision}:{uuid.uuid4().hex}"
        return PatchPreview(
            patch_id=_stable_id("patch", document.document_id, patch_identity),
            document_id=document.document_id,
            base_revision=document.revision,
            issue_id=issue.issue_id,
            tool_name=tool_name,
            status=status,
            roi=roi,
            summary=summary,
            evidence=[
                "existing analyze_circuit_image_adaptive pipeline rerun on issue ROI",
                "existing port-aware electrical topology output compared by node geometry",
                "no GraphDocument mutation performed during retry",
            ],
            operations=operations,
            analysis_snapshot={
                "roi_width": roi.x_max - roi.x_min,
                "roi_height": roi.y_max - roi.y_min,
                "detected_nodes": len(raw_nodes),
                "detected_lines": len(result.get("lines", [])),
                "matched_existing_nodes": len(mapping) - len(new_node_ids),
                "unmatched_nodes": len(unmatched),
                "proposed_node_additions": node_additions,
                "proposed_edge_additions": edge_additions,
            },
            created_at=datetime.now(timezone.utc),
        )


review_tool_runner = ReviewVisionToolRunner()


__all__ = [
    "ReviewToolInputError",
    "ReviewToolUnavailableError",
    "configure_review_tools",
    "review_tool_runner",
]

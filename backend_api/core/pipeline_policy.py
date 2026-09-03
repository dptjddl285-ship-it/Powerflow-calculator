"""Adaptive policy layer for the PowerLens vision pipeline.

The production detectors contain the pixel-level implementation.  This module
owns the rules that should remain stable across diagram styles:

* inspect image quality before choosing pixel tolerances;
* keep object pixels and text-clean conductor pixels as separate layers;
* express every candidate outcome as accept, rescue, review, or reject;
* never let a rescue bypass an electrical/topological mandatory condition;
* validate the final graph before it is handed to power-flow calculation.

The policy deliberately works with normalized evidence instead of OpenCV
contours.  Detectors can therefore evolve without copying thresholds into the
FastAPI endpoint or Flutter application.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import Enum
from typing import Any, Iterable, Mapping

import cv2
import numpy as np


PIPELINE_POLICY_VERSION = "2.0"


class DecisionState(str, Enum):
    ACCEPT = "accept"
    RESCUE = "rescue"
    REVIEW = "review"
    REJECT = "reject"


@dataclass(frozen=True)
class ImageProfile:
    width: int
    height: int
    min_side: int
    max_side: int
    contrast_span: float
    blur_variance: float
    foreground_ratio: float
    estimated_stroke: float
    low_resolution: bool
    low_contrast: bool
    blurry: bool
    recommended_scale: float
    tags: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class AdaptiveThresholds:
    pixel_scale: float
    bus_min_aspect: float
    bus_min_straightness: float
    bus_min_profile: float
    bus_min_stroke_ratio: float
    bus_max_endpoint_bends: int
    bus_rescue_max_gap: int
    load_min_triangle_score: float
    load_max_lead: int
    load_rescue_max_lead: int
    topology_contact_margin: int
    transformer_pair_min_score: float

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class CandidateEvidence:
    """Detector-independent evidence used by the candidate policy.

    Values that do not apply to a class may remain ``None``.  Mandatory rules
    never infer missing evidence as success.
    """

    class_name: str
    bbox: tuple[float, float, float, float]
    source: str = "unknown"
    yolo_confidence: float = 0.0
    cv_score: float = 0.0
    aspect_ratio: float | None = None
    stroke_ratio: float | None = None
    straightness: float | None = None
    profile_score: float | None = None
    branch_count: int | None = None
    endpoint_bends: int | None = None
    fragmented_gap: int | None = None
    triangle_score: float | None = None
    compactness: float | None = None
    attached_to_bus: bool | None = None
    tail_continuity: float | None = None
    lead_length: int | None = None
    tip_continues: bool | None = None
    enclosed_hole: bool | None = None
    terminal_connected: bool | None = None
    transformer_pair: bool | None = None
    wave_pair_score: float | None = None
    circle_pair_score: float | None = None
    text_overlap: float = 0.0
    box_area_ratio: float = 0.0
    tags: set[str] = field(default_factory=set)


@dataclass(frozen=True)
class CandidateDecision:
    state: DecisionState
    reasons: tuple[str, ...]
    mandatory_passed: bool
    rescue_kind: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "state": self.state.value,
            "reasons": list(self.reasons),
            "mandatory_passed": self.mandatory_passed,
            "rescue_kind": self.rescue_kind,
        }


@dataclass(frozen=True)
class GraphIssue:
    severity: str
    code: str
    message: str
    component_ids: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def inspect_image(image: np.ndarray) -> ImageProfile:
    if image is None or image.size == 0:
        raise ValueError("Cannot profile an empty image")
    gray = image if image.ndim == 2 else cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    height, width = gray.shape[:2]
    min_side, max_side = min(width, height), max(width, height)
    p05, p95 = np.percentile(gray, (5, 95))
    contrast_span = float(p95 - p05)
    blur_variance = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    foreground_ratio = float(np.count_nonzero(binary) / max(binary.size, 1))

    distance = cv2.distanceTransform(binary, cv2.DIST_L2, 3)
    positive = distance[(distance > 0) & (distance <= 6.0)]
    estimated_stroke = (
        float(np.percentile(positive, 45) * 2.0) if positive.size else 1.0
    )
    estimated_stroke = float(np.clip(estimated_stroke, 1.0, 12.0))

    low_resolution = min_side < 720 or estimated_stroke < 1.6
    low_contrast = contrast_span < 90.0
    # Line drawings naturally have lower Laplacian variance than photographs;
    # use a conservative blur threshold so a clean sparse drawing is not
    # sharpened unnecessarily.
    blurry = blur_variance < 45.0

    if low_resolution:
        side_scale = 900.0 / max(min_side, 1)
        stroke_scale = 2.6 / max(estimated_stroke, 0.5)
        recommended_scale = float(np.clip(max(side_scale, stroke_scale), 1.25, 3.0))
    elif max_side > 2800:
        recommended_scale = float(2400.0 / max_side)
    else:
        recommended_scale = 1.0

    tags: list[str] = []
    if low_resolution:
        tags.append("low_resolution")
    if low_contrast:
        tags.append("low_contrast")
    if blurry:
        tags.append("blurry")
    if foreground_ratio < 0.002:
        tags.append("sparse_ink")
    elif foreground_ratio > 0.22:
        tags.append("dense_ink_or_background_noise")
    if not tags:
        tags.append("normal")

    return ImageProfile(
        width=width,
        height=height,
        min_side=min_side,
        max_side=max_side,
        contrast_span=contrast_span,
        blur_variance=blur_variance,
        foreground_ratio=foreground_ratio,
        estimated_stroke=estimated_stroke,
        low_resolution=low_resolution,
        low_contrast=low_contrast,
        blurry=blurry,
        recommended_scale=recommended_scale,
        tags=tuple(tags),
    )


def thresholds_for(profile: ImageProfile) -> AdaptiveThresholds:
    scale = max(profile.recommended_scale, 1.0)
    stroke = max(profile.estimated_stroke * scale, 1.0)
    return AdaptiveThresholds(
        pixel_scale=scale,
        bus_min_aspect=2.6 if profile.low_resolution else 3.0,
        bus_min_straightness=0.90 if profile.low_resolution else 0.94,
        bus_min_profile=0.76 if profile.low_resolution else 0.82,
        bus_min_stroke_ratio=1.15 if profile.low_resolution else 1.35,
        bus_max_endpoint_bends=0,
        bus_rescue_max_gap=max(2, int(round(stroke * (1.8 if profile.low_resolution else 1.2)))),
        load_min_triangle_score=0.34 if profile.low_resolution else 0.38,
        load_max_lead=max(160, int(round(stroke * 28))),
        load_rescue_max_lead=max(50, int(round(stroke * 8))),
        topology_contact_margin=max(4, int(round(stroke * 1.5))),
        transformer_pair_min_score=0.62 if profile.low_resolution else 0.70,
    )


class CandidatePolicy:
    def __init__(self, profile: ImageProfile):
        self.profile = profile
        self.thresholds = thresholds_for(profile)

    def decide(self, evidence: CandidateEvidence) -> CandidateDecision:
        class_name = evidence.class_name.strip().lower()
        if self._monster_box(evidence):
            return self._reject("page-sized or monster bounding box")
        if class_name == "bus":
            return self._bus(evidence)
        if class_name == "load":
            return self._load(evidence)
        if class_name == "generator":
            return self._generator(evidence)
        if class_name == "transformer":
            return self._transformer(evidence)
        return self._reject(f"unsupported class: {class_name}")

    @staticmethod
    def _monster_box(evidence: CandidateEvidence) -> bool:
        _, _, width, height = evidence.bbox
        return evidence.box_area_ratio > 0.35 or (
            evidence.box_area_ratio > 0.18 and min(width, height) > 0
            and max(width, height) / min(width, height) < 1.5
        )

    def _bus(self, e: CandidateEvidence) -> CandidateDecision:
        t = self.thresholds
        missing = self._missing(
            e,
            "aspect_ratio",
            "straightness",
            "profile_score",
            "stroke_ratio",
            "branch_count",
            "endpoint_bends",
        )
        if missing:
            return self._review(f"bus evidence missing: {', '.join(missing)}")
        if e.endpoint_bends > t.bus_max_endpoint_bends:
            return self._reject("bus axis bends at an endpoint")
        if e.branch_count < 1:
            return self._reject("bus has no physical incoming/outgoing branch")
        if e.text_overlap > 0.45:
            return self._reject("candidate is dominated by text strokes")

        normal = (
            e.aspect_ratio >= t.bus_min_aspect
            and e.straightness >= t.bus_min_straightness
            and e.profile_score >= t.bus_min_profile
            and e.stroke_ratio >= t.bus_min_stroke_ratio
        )
        if normal:
            return self._accept("straight thick bar with branch and stable profile")

        fragmented = (
            e.fragmented_gap is not None
            and e.fragmented_gap <= t.bus_rescue_max_gap
            and e.aspect_ratio >= t.bus_min_aspect
            and e.profile_score >= t.bus_min_profile
            and e.yolo_confidence >= 0.30
        )
        if fragmented:
            return self._rescue(
                "fragmented low-resolution bar repaired with CV geometry and YOLO support",
                "fragmented_bus",
            )
        return self._reject("bus thickness/straightness/profile family is inconsistent")

    def _load(self, e: CandidateEvidence) -> CandidateDecision:
        t = self.thresholds
        if e.attached_to_bus is not True:
            return self._reject("load tail is not physically connected to a detected bus")
        if e.tail_continuity is None or e.tail_continuity < 0.78:
            return self._reject("load tail does not form a continuous conductor path")
        if e.enclosed_hole is True:
            return self._reject("number-like enclosed hole inside load candidate")
        if e.lead_length is None:
            return self._review("load lead length was not measured")
        if e.lead_length > t.load_max_lead:
            return self._reject("load lead is implausibly long")
        if e.tip_continues is True and "outline_yolo" not in e.tags:
            return self._reject("arrow tip continues into a through conductor")

        triangle_ok = (
            e.triangle_score is not None
            and e.triangle_score >= t.load_min_triangle_score
        )
        if triangle_ok:
            return self._accept("compact arrowhead with a validated tail-to-bus path")

        outline_rescue = (
            e.yolo_confidence >= 0.35
            and "outline_yolo" in e.tags
            and e.lead_length <= t.load_max_lead
            and "long_through_line" not in e.tags
        )
        if outline_rescue:
            return self._rescue(
                "outline arrow recovered by YOLO proposal plus mandatory CV bus trace",
                "outline_load",
            )

        tiny_rescue = (
            self.profile.low_resolution
            and e.triangle_score is not None
            and e.triangle_score >= 0.30
            and e.lead_length <= t.load_rescue_max_lead
            and (e.compactness or 0.0) >= 0.30
        )
        if tiny_rescue:
            return self._rescue(
                "tiny low-resolution arrow recovered close to its bus",
                "tiny_load",
            )
        return self._reject("candidate lacks sufficient arrowhead evidence")

    def _generator(self, e: CandidateEvidence) -> CandidateDecision:
        if e.transformer_pair is True:
            return self._reject("overlapping transformer windings are not a generator")
        if e.yolo_confidence < 0.50:
            return self._reject("generator semantic confidence is too low")
        if e.terminal_connected is True:
            return self._accept("generator symbol has a validated terminal-to-bus path")
        if e.yolo_confidence >= 0.80:
            return self._review(
                "high-confidence standalone generator/legend symbol needs topology confirmation"
            )
        return self._reject("generator has no validated electrical terminal")

    def _transformer(self, e: CandidateEvidence) -> CandidateDecision:
        pair_score = max(e.wave_pair_score or 0.0, e.circle_pair_score or 0.0)
        if pair_score >= self.thresholds.transformer_pair_min_score:
            if e.yolo_confidence >= 0.70:
                return self._accept("CV winding pair confirmed by semantic proposal")
            return self._review("structural winding pair lacks independent semantic confirmation")
        local_rescue = (
            e.yolo_confidence >= 0.70
            and e.transformer_pair is True
            and pair_score >= self.thresholds.transformer_pair_min_score - 0.10
        )
        if local_rescue:
            return self._rescue(
                "faint/fragmented winding pair recovered by local CV inspection",
                "local_transformer_pair",
            )
        return self._reject("no valid opposing-wave or overlapping-circle pair")

    @staticmethod
    def _missing(evidence: CandidateEvidence, *names: str) -> list[str]:
        return [name for name in names if getattr(evidence, name) is None]

    @staticmethod
    def _accept(reason: str) -> CandidateDecision:
        return CandidateDecision(DecisionState.ACCEPT, (reason,), True)

    @staticmethod
    def _rescue(reason: str, rescue_kind: str) -> CandidateDecision:
        return CandidateDecision(
            DecisionState.RESCUE,
            (reason,),
            True,
            rescue_kind=rescue_kind,
        )

    @staticmethod
    def _review(reason: str) -> CandidateDecision:
        return CandidateDecision(DecisionState.REVIEW, (reason,), False)

    @staticmethod
    def _reject(reason: str) -> CandidateDecision:
        return CandidateDecision(DecisionState.REJECT, (reason,), False)


def validate_graph(
    nodes: Iterable[Mapping[str, Any]],
    lines: Iterable[Mapping[str, Any]],
) -> list[GraphIssue]:
    node_list = list(nodes)
    line_list = list(lines)
    classes = {
        str(node.get("id")): str(node.get("class", "")).lower()
        for node in node_list
        if node.get("id") is not None
    }
    degree = {node_id: 0 for node_id in classes}
    nodes_by_id = {
        str(node.get("id")): node
        for node in node_list
        if node.get("id") is not None
    }
    transformer_sides: dict[str, set[str]] = {
        node_id: set()
        for node_id, class_name in classes.items()
        if class_name == "transformer"
    }
    issues: list[GraphIssue] = []
    seen_pairs: set[tuple[str, str]] = set()

    for line in line_list:
        endpoints = line.get("connected_to")
        if not isinstance(endpoints, (list, tuple)) or len(endpoints) != 2:
            issues.append(GraphIssue("error", "invalid_line_endpoints", "Line must have exactly two endpoints"))
            continue
        first, second = str(endpoints[0]), str(endpoints[1])
        if first == second:
            issues.append(GraphIssue("error", "self_loop", "A component cannot connect to itself", (first,)))
            continue
        unknown = tuple(node_id for node_id in (first, second) if node_id not in classes)
        if unknown:
            issues.append(GraphIssue("error", "unknown_endpoint", "Line references an unknown component", unknown))
            continue
        degree[first] += 1
        degree[second] += 1

        path = line.get("path")
        for endpoint_index, component_id, port_key in (
            (0, first, "source_port"),
            (-1, second, "target_port"),
        ):
            if classes.get(component_id) != "transformer":
                continue
            side = str(line.get(port_key, "")).lower()
            if side not in {"top", "bottom", "left", "right"}:
                node = nodes_by_id.get(component_id, {})
                bbox = node.get("bbox")
                if (
                    isinstance(path, (list, tuple))
                    and path
                    and isinstance(bbox, (list, tuple))
                    and len(bbox) == 4
                    and isinstance(path[endpoint_index], (list, tuple))
                    and len(path[endpoint_index]) >= 2
                ):
                    cx, cy, box_width, box_height = (
                        float(value) for value in bbox
                    )
                    px, py = (
                        float(path[endpoint_index][0]),
                        float(path[endpoint_index][1]),
                    )
                    metadata = node.get("metadata") or {}
                    transformer = metadata.get("transformer") or {}
                    orientation = str(transformer.get("orientation", ""))
                    if orientation not in {"vertical", "horizontal"}:
                        orientation = (
                            "vertical" if box_height >= box_width else "horizontal"
                        )
                    side = (
                        ("top" if py < cy else "bottom")
                        if orientation == "vertical"
                        else ("left" if px < cx else "right")
                    )
            if side in {"top", "bottom", "left", "right"}:
                transformer_sides[component_id].add(side)

        endpoint_classes = {classes[first], classes[second]}
        if endpoint_classes <= {"load", "generator"}:
            issues.append(GraphIssue("error", "invalid_device_pair", "Load/generator devices must connect through a bus", pair))

    for node_id, class_name in classes.items():
        node_degree = degree[node_id]
        if class_name in {"load", "generator"} and node_degree != 1:
            issues.append(GraphIssue(
                "error",
                "invalid_terminal_degree",
                f"{class_name} must have exactly one electrical connection; found {node_degree}",
                (node_id,),
            ))
        # A transformer may have multiple conductors on either electrical
        # side, so total degree alone is insufficient.  Require evidence for
        # both opposite sides while allowing 2+2 (degree 4) arrangements.
        elif class_name == "transformer":
            node = nodes_by_id.get(node_id, {})
            metadata = node.get("metadata") or {}
            transformer = metadata.get("transformer") or {}
            orientation = str(transformer.get("orientation", ""))
            if orientation not in {"vertical", "horizontal"}:
                bbox = node.get("bbox")
                if isinstance(bbox, (list, tuple)) and len(bbox) == 4:
                    orientation = (
                        "vertical"
                        if float(bbox[3]) >= float(bbox[2])
                        else "horizontal"
                    )
            expected_sides = (
                {"left", "right"}
                if orientation == "horizontal"
                else {"top", "bottom"}
            )
            connected_sides = transformer_sides.get(node_id, set())
            if node_degree == 0:
                issues.append(GraphIssue(
                    "warning",
                    "invalid_transformer_degree",
                    "변압기에 추적된 전기 연결이 없습니다.",
                    (node_id,),
                ))
            elif node_degree == 1 or not expected_sides.issubset(connected_sides):
                side_text = ", ".join(sorted(connected_sides)) or "확인 불가"
                issues.append(GraphIssue(
                    "error",
                    "invalid_transformer_degree",
                    "변압기의 양측 전기 포트가 모두 연결되어야 합니다; "
                    f"현재 연결 측: {side_text}",
                    (node_id,),
                ))
        elif class_name == "bus" and node_degree == 0:
            issues.append(GraphIssue(
                "warning",
                "isolated_bus",
                "Bus has no traced electrical connection",
                (node_id,),
            ))
    return issues


def build_runtime_report(
    profile: ImageProfile,
    nodes: Iterable[Mapping[str, Any]],
    lines: Iterable[Mapping[str, Any]],
    processing_scale: float,
) -> dict[str, Any]:
    node_list = list(nodes)
    line_list = list(lines)
    issues = validate_graph(node_list, line_list)
    decisions = []
    degree: dict[str, int] = {str(node.get("id")): 0 for node in node_list}
    for line in line_list:
        endpoints = line.get("connected_to", ())
        if isinstance(endpoints, (list, tuple)):
            for endpoint in endpoints:
                endpoint = str(endpoint)
                if endpoint in degree:
                    degree[endpoint] += 1
    for node in node_list:
        source = str(node.get("source", "unknown"))
        node_id = str(node.get("id", "unknown"))
        if "rescue" in source:
            state = DecisionState.RESCUE.value
        elif source == "yolo_generator_symbol" and degree.get(node_id, 0) == 0:
            state = DecisionState.REVIEW.value
        else:
            state = DecisionState.ACCEPT.value
        decisions.append({
            "id": node_id,
            "class": node.get("class"),
            "state": state,
            "source": source,
            "degree": degree.get(node_id, 0),
        })

    retry_plan: list[str] = []
    if profile.low_resolution:
        retry_plan.append("upscale_to_stable_stroke_width")
    if profile.low_contrast:
        retry_plan.append("clahe_for_conductor_mask_only")
    if profile.blurry:
        retry_plan.append("mark_for_review_if_thin_wires_remain_broken")
    if any(issue.code == "invalid_terminal_degree" for issue in issues):
        retry_plan.append("local_port_retrace_around_unconnected_device")
    if any(issue.code == "isolated_bus" for issue in issues):
        retry_plan.append("local_branch_retrace_around_isolated_bus")

    has_error = any(issue.severity == "error" for issue in issues)
    has_warning = any(issue.severity == "warning" for issue in issues)
    return {
        "version": PIPELINE_POLICY_VERSION,
        "status": "needs_review" if has_error or has_warning else "ready",
        "image_profile": profile.to_dict(),
        "thresholds": thresholds_for(profile).to_dict(),
        "processing_scale": float(processing_scale),
        "layers": {
            "object_layer": "original_or_quality_normalized_grayscale",
            "topology_layer": "text_filtered_conductor_mask",
        },
        "node_decisions": decisions,
        "graph_issues": [issue.to_dict() for issue in issues],
        "retry_plan": retry_plan,
    }

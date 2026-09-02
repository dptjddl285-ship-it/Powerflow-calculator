"""Convert the legacy Vision result into a versioned GraphDocument."""

from __future__ import annotations

import hashlib
import json
from statistics import median
import uuid
from copy import deepcopy
from typing import Any, Mapping, Sequence

from .graph_document import (
    CenterBBox,
    GraphDocument,
    GraphEdge,
    GraphNode,
    GraphStatus,
    ImageMetadata,
    PixelPoint,
    Port,
    RescueRecord,
    ReviewIssue,
    ReviewState,
    VerificationRecord,
)


_RESCUE_SOURCES = {
    "yolo_rescue": "yolo_candidate_cv_confirmation",
    "yolo_port_rescue": "load_port_trace",
    "yolo_cv_raster_run": "bus_raster_reconstruction",
    "cv_secondary_electrical_family": "secondary_cv_electrical_family",
}

_RETRY_TOOL_BY_CODE = {
    "invalid_terminal_degree": "port_aware_retry",
    "isolated_bus": "roi_reanalysis",
    "invalid_transformer_degree": "port_aware_retry",
    "invalid_line_endpoints": "validate_topology",
    "unknown_endpoint": "validate_topology",
}


def _stable_id(prefix: str, document_id: str, identity: str) -> str:
    value = uuid.uuid5(uuid.NAMESPACE_URL, f"powerlens:{document_id}:{identity}")
    return f"{prefix}_{value.hex[:16]}"


def _make_document_id(
    result: Mapping[str, Any],
    image_bytes: bytes | None,
) -> str:
    if image_bytes:
        digest = hashlib.sha256(image_bytes).hexdigest()
    else:
        canonical = json.dumps(
            {"nodes": result.get("nodes", []), "lines": result.get("lines", [])},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        digest = hashlib.sha256(canonical).hexdigest()
    return f"graph_{digest[:20]}"


def _bbox(raw: Sequence[Any]) -> CenterBBox:
    if len(raw) != 4:
        raise ValueError(f"bbox must contain center_x, center_y, width, height: {raw!r}")
    return CenterBBox(
        center_x=float(raw[0]),
        center_y=float(raw[1]),
        width=float(raw[2]),
        height=float(raw[3]),
    )


def _point(raw: Sequence[Any]) -> PixelPoint:
    if len(raw) != 2:
        raise ValueError(f"path point must contain x and y: {raw!r}")
    return PixelPoint(x=float(raw[0]), y=float(raw[1]))


def _rescue_kind(source: str) -> str | None:
    if source in _RESCUE_SOURCES:
        return _RESCUE_SOURCES[source]
    if "rescue" in source:
        return source
    return None


def _port_side(raw_port: Any, fallback: str) -> str:
    if isinstance(raw_port, Mapping):
        return str(raw_port.get("side") or fallback)
    if isinstance(raw_port, str) and raw_port:
        return raw_port
    return fallback


def _optional_float(raw_port: Any, key: str) -> float | None:
    if not isinstance(raw_port, Mapping) or raw_port.get(key) is None:
        return None
    return float(raw_port[key])


def _suggested_tools(code: str) -> list[str]:
    tool = _RETRY_TOOL_BY_CODE.get(code)
    return [tool] if tool else ["validate_topology"]


def build_graph_document(
    vision_result: Mapping[str, Any],
    *,
    image_bytes: bytes | None = None,
    filename: str | None = None,
) -> GraphDocument:
    """Build a GraphDocument without mutating the legacy result.

    Automatic rescue means the deterministic hybrid Vision pipeline accepted a
    missing candidate after class-specific CV evidence. It is recorded as
    ``auto_rescued`` but remains reviewable; this is not an LLM-authored object.
    """

    result = deepcopy(dict(vision_result))
    document_id = _make_document_id(result, image_bytes)
    pipeline = dict(result.get("pipeline") or {})
    profile = dict(pipeline.get("image_profile") or {})
    decisions = {
        str(item.get("id")): str(item.get("state", "accepted"))
        for item in pipeline.get("node_decisions", [])
        if isinstance(item, Mapping) and item.get("id") is not None
    }

    node_id_map: dict[str, str] = {}
    nodes: list[GraphNode] = []
    rescues: list[RescueRecord] = []

    for raw_node in result.get("nodes", []):
        source_id = str(raw_node["id"])
        class_name = str(raw_node["class"]).lower()
        source = str(raw_node.get("source", "unknown"))
        internal_id = _stable_id("node", document_id, f"{class_name}:{source_id}")
        node_id_map[source_id] = internal_id
        rescue_kind = _rescue_kind(source)
        decision = decisions.get(source_id, "accepted")
        if decision == "review":
            review_state = ReviewState.NEEDS_REVIEW
        elif rescue_kind is not None or decision == "rescue":
            review_state = ReviewState.AUTO_RESCUED
        else:
            review_state = ReviewState.ACCEPTED
        confidence = max(0.0, min(1.0, float(raw_node.get("confidence", 0.0))))
        bbox = _bbox(raw_node["bbox"])
        nodes.append(GraphNode(
            internal_id=internal_id,
            source_id=source_id,
            type=class_name,
            bbox=bbox,
            original_bbox=bbox.model_copy(deep=True),
            confidence=confidence,
            source=source,
            review_state=review_state,
        ))
        if review_state == ReviewState.AUTO_RESCUED:
            kind = rescue_kind or str(raw_node.get("rescue_kind") or "policy_rescue")
            rescues.append(RescueRecord(
                rescue_id=_stable_id("rescue", document_id, source_id),
                node_id=internal_id,
                source=source,
                rescue_kind=kind,
                confidence=confidence,
                evidence=[
                    f"source={source}",
                    f"pipeline_decision={decision}",
                    "class-specific deterministic CV gate passed",
                ],
            ))

    ports: list[Port] = []
    edges: list[GraphEdge] = []
    adapter_issues: list[dict[str, Any]] = []
    node_ports: dict[str, list[str]] = {node.internal_id: [] for node in nodes}

    for index, raw_line in enumerate(result.get("lines", [])):
        source_line_id = str(raw_line.get("line_id", f"line_{index}"))
        endpoints = list(raw_line.get("connected_to") or [])
        path_raw = list(raw_line.get("path") or [])
        if len(endpoints) != 2 or len(path_raw) < 2:
            adapter_issues.append({
                "severity": "error",
                "code": "adapter_invalid_edge",
                "message": f"{source_line_id} has invalid endpoints or pixel path",
                "component_ids": [str(value) for value in endpoints],
            })
            continue
        source_node_id = node_id_map.get(str(endpoints[0]))
        target_node_id = node_id_map.get(str(endpoints[1]))
        if source_node_id is None or target_node_id is None:
            adapter_issues.append({
                "severity": "error",
                "code": "adapter_unknown_endpoint",
                "message": f"{source_line_id} references an unknown Vision node",
                "component_ids": [str(value) for value in endpoints],
            })
            continue
        path = [_point(item) for item in path_raw]
        edge_id = _stable_id("edge", document_id, source_line_id)
        source_port_id = _stable_id("port", document_id, f"{source_line_id}:source")
        target_port_id = _stable_id("port", document_id, f"{source_line_id}:target")
        raw_source_port = raw_line.get("source_port")
        raw_target_port = raw_line.get("target_port")
        ports.extend([
            Port(
                port_id=source_port_id,
                node_id=source_node_id,
                side=_port_side(raw_source_port, "boundary"),
                point=path[0],
                score=_optional_float(raw_source_port, "score"),
                distance=_optional_float(raw_source_port, "distance"),
            ),
            Port(
                port_id=target_port_id,
                node_id=target_node_id,
                side=_port_side(raw_target_port, "boundary"),
                point=path[-1],
                score=_optional_float(raw_target_port, "score"),
                distance=_optional_float(raw_target_port, "distance"),
            ),
        ])
        node_ports[source_node_id].append(source_port_id)
        node_ports[target_node_id].append(target_port_id)
        edges.append(GraphEdge(
            internal_id=edge_id,
            source_id=source_line_id,
            source_node_id=source_node_id,
            target_node_id=target_node_id,
            source_port_id=source_port_id,
            target_port_id=target_port_id,
            path=path,
            trace_method=str(raw_line.get("trace_method", "skeleton")),
        ))

    for node in nodes:
        node.ports = node_ports[node.internal_id]

    # A conductor fragment may occasionally survive the detector's bus gate.
    # Compare bus thickness within this image instead of using an absolute
    # pixel threshold, so low-resolution diagrams keep their own scale.
    bus_nodes = [node for node in nodes if node.type == "bus"]
    bus_thicknesses = [
        min(node.bbox.width, node.bbox.height)
        for node in bus_nodes
        if max(node.bbox.width, node.bbox.height)
        >= min(node.bbox.width, node.bbox.height) * 3.0
    ]
    if len(bus_thicknesses) >= 3:
        family_thickness = float(median(bus_thicknesses))
        for node in bus_nodes:
            short_side = min(node.bbox.width, node.bbox.height)
            long_side = max(node.bbox.width, node.bbox.height)
            if long_side < short_side * 3.0:
                continue
            thickness_ratio = short_side / max(family_thickness, 1e-6)
            if thickness_ratio >= 0.55:
                continue
            adapter_issues.append({
                "severity": "warning",
                "code": "suspicious_bus_thickness",
                "message": (
                    "Bus candidate is much thinner than the bus family in this image; "
                    "a conductor segment may have been classified as a bus"
                ),
                "component_ids": [node.source_id],
            })

    raw_issues = list(pipeline.get("graph_issues") or []) + adapter_issues
    issues: list[ReviewIssue] = []
    for index, raw_issue in enumerate(raw_issues):
        code = str(raw_issue.get("code", "unknown_issue"))
        source_component_ids = [str(value) for value in raw_issue.get("component_ids", [])]
        component_ids = [node_id_map.get(value, value) for value in source_component_ids]
        issue_identity = f"{code}:{index}:{','.join(source_component_ids)}"
        severity = str(raw_issue.get("severity", "warning")).lower()
        if severity not in {"error", "warning", "info"}:
            severity = "warning"
        issues.append(ReviewIssue(
            issue_id=_stable_id("issue", document_id, issue_identity),
            severity=severity,
            code=code,
            message=str(raw_issue.get("message", code)),
            component_ids=component_ids,
            suggested_tools=_suggested_tools(code),
        ))

    issue_ids = [issue.issue_id for issue in issues]
    critical_count = sum(issue.severity == "error" for issue in issues)
    verification = VerificationRecord(
        issue_count=len(issues),
        critical_issue_count=critical_count,
        unresolved_issues=issue_ids,
    )
    return GraphDocument(
        document_id=document_id,
        revision=1,
        status=GraphStatus.IN_REVIEW,
        image_metadata=ImageMetadata(
            filename=filename,
            width=int(profile.get("width", 0) or 0),
            height=int(profile.get("height", 0) or 0),
        ),
        nodes=nodes,
        edges=edges,
        ports=ports,
        issues=issues,
        rescues=rescues,
        verification=verification,
        retry_plan=[str(value) for value in pipeline.get("retry_plan", [])],
        pipeline_metadata={
            "version": pipeline.get("version"),
            "status": pipeline.get("status"),
            "processing_scale": pipeline.get("processing_scale"),
            "layers": pipeline.get("layers", {}),
        },
    )


__all__ = ["build_graph_document"]

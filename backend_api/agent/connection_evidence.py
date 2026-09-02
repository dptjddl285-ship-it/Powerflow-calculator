"""Connection Evidence Extractor and Topology Issue Mapper for VisionFlow SLD."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Mapping, Optional, Sequence

from core.pipeline_policy import GraphIssue, validate_graph


@dataclass
class ConnectionEvidence:
    line_id: str
    connected_to: List[str]
    source_port: str = "auto"
    target_port: str = "auto"
    trace_method: str = "electrical_graph"
    path: List[List[float]] = field(default_factory=list)
    validation_issues: List[Dict[str, Any]] = field(default_factory=list)
    geometry: Dict[str, Any] = field(default_factory=dict)
    candidate_connections: List[str] = field(default_factory=list)
    review_status: str = "DETECTED"  # DETECTED, AMBIGUOUS, CONFIRMED, REJECTED
    source: str = "ai_detected"  # ai_detected, human_corrected, human_added
    is_ambiguous: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return {
            "line_id": self.line_id,
            "connected_to": self.connected_to,
            "source_port": self.source_port,
            "target_port": self.target_port,
            "trace_method": self.trace_method,
            "path": self.path,
            "validation_issues": self.validation_issues,
            "geometry": self.geometry,
            "candidate_connections": self.candidate_connections,
            "review_status": self.review_status,
            "source": self.source,
            "is_ambiguous": self.is_ambiguous,
        }


def extract_connection_evidence(
    line: Mapping[str, Any],
    all_nodes: Sequence[Mapping[str, Any]],
    all_lines: Sequence[Mapping[str, Any]],
    graph_issues: Optional[List[GraphIssue]] = None,
) -> ConnectionEvidence:
    """Extract structured evidence and validation status for a single line."""
    line_id = str(line.get("line_id", line.get("id", "L_unknown")))
    connected_to = [str(x) for x in line.get("connected_to", [])]
    source_port = str(line.get("source_port", "auto"))
    target_port = str(line.get("target_port", "auto"))
    trace_method = str(line.get("trace_method", "electrical_graph"))
    raw_path = line.get("path", [])
    path = [[float(pt[0]), float(pt[1])] for pt in raw_path if isinstance(pt, (list, tuple)) and len(pt) >= 2]
    source = str(line.get("source", "ai_detected"))
    current_status = str(line.get("review_status", "DETECTED")).upper()

    # Calculate path length geometry
    path_len = 0.0
    for i in range(len(path) - 1):
        dx = path[i + 1][0] - path[i][0]
        dy = path[i + 1][1] - path[i][1]
        path_len += (dx * dx + dy * dy) ** 0.5

    geometry = {
        "path_length": round(path_len, 2),
        "point_count": len(path),
    }

    # Run deterministic graph validation if not provided
    if graph_issues is None:
        graph_issues = validate_graph(all_nodes, all_lines)

    # Filter issues relating to this line or its endpoints
    line_issues: List[Dict[str, Any]] = []
    endpoint_set = set(connected_to)

    for issue in graph_issues:
        issue_dict = issue.to_dict()
        issue_components = set(issue.component_ids)
        # Issue relates to this line if component_ids overlap with endpoints or line_id
        if issue_components & endpoint_set or line_id in issue_components:
            line_issues.append(issue_dict)
        elif issue.code == "invalid_line_endpoints" and len(connected_to) != 2:
            line_issues.append(issue_dict)

    # Additional heuristics: dangling / single endpoint
    if len(connected_to) < 2:
        line_issues.append({
            "severity": "error",
            "code": "dangling_connection",
            "message": f"선로 {line_id}의 끝점이 1개 이하입니다.",
            "component_ids": tuple(connected_to),
        })

    is_ambiguous = len(line_issues) > 0 and current_status != "CONFIRMED"
    if current_status == "REJECTED":
        status = "REJECTED"
    elif current_status == "CONFIRMED":
        status = "CONFIRMED"
    elif is_ambiguous:
        status = "AMBIGUOUS"
    else:
        status = "DETECTED"

    # Candidate target buses for reconnection
    candidate_buses = [
        str(n.get("id"))
        for n in all_nodes
        if str(n.get("class", "")).lower() == "bus" and str(n.get("id")) not in endpoint_set
    ]

    return ConnectionEvidence(
        line_id=line_id,
        connected_to=connected_to,
        source_port=source_port,
        target_port=target_port,
        trace_method=trace_method,
        path=path,
        validation_issues=line_issues,
        geometry=geometry,
        candidate_connections=candidate_buses[:5],
        review_status=status,
        source=source,
        is_ambiguous=is_ambiguous,
    )


def extract_all_connections_evidence(
    nodes: Sequence[Mapping[str, Any]],
    lines: Sequence[Mapping[str, Any]],
) -> List[Dict[str, Any]]:
    """Annotate all lines with connection evidence and validation issues."""
    graph_issues = validate_graph(nodes, lines)
    annotated: List[Dict[str, Any]] = []

    for line in lines:
        ev = extract_connection_evidence(line, nodes, lines, graph_issues=graph_issues)
        line_dict = dict(line)
        line_dict["review_status"] = ev.review_status
        line_dict["source"] = ev.source
        line_dict["validation_issues"] = ev.validation_issues
        line_dict["evidence"] = ev.to_dict()
        annotated.append(line_dict)

    return annotated

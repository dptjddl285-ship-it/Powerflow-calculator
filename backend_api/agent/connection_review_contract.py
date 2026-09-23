"""Deterministic Connection Review V2 contract helpers.

Connection Review uses the same exception-first contract at every boundary:
clean active lines are accepted automatically, while only ambiguous lines and
authoritative severity=error evidence require attention.  This module contains
no LLM policy and never invents a line or issue identifier.
"""
from __future__ import annotations

from typing import Any, Iterable, Mapping


CONNECTION_NO_ACTIVE_MESSAGE = (
    "유효한 결선 선로가 없습니다. 결선 검출을 확인해주세요."
)


def _status(item: Mapping[str, Any]) -> str:
    return str(item.get("review_status") or item.get("status") or "DETECTED").upper()


def active_connection_lines(
    lines: Iterable[Mapping[str, Any]],
) -> list[Mapping[str, Any]]:
    return [line for line in lines if _status(line) != "REJECTED"]


def is_error_issue(issue: Mapping[str, Any]) -> bool:
    return str(issue.get("severity", "")).lower() == "error"


def line_validation_issues(line: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    raw = line.get("validation_issues")
    if not isinstance(raw, list):
        evidence = line.get("evidence")
        raw = evidence.get("validation_issues") if isinstance(evidence, Mapping) else []
    return [item for item in raw if isinstance(item, Mapping)]


def line_has_critical_issue(line: Mapping[str, Any]) -> bool:
    return any(is_error_issue(issue) for issue in line_validation_issues(line))


def _contains_crossing_key(key: Any) -> bool:
    normalized = str(key or "").lower()
    return any(token in normalized for token in ("cross", "overlap", "intersection", "교차"))


def _crossing_value_exists(value: Any) -> bool:
    if value is None or value is False:
        return False
    if isinstance(value, str):
        return value.strip().lower() not in {"", "false", "none", "null"}
    if isinstance(value, (list, tuple, set, dict)):
        return bool(value)
    return True


def has_crossing_evidence(line: Mapping[str, Any]) -> bool:
    """Detect explicit crossing/overlap evidence without inferring from path."""
    def inspect(value: Any) -> bool:
        if not isinstance(value, Mapping):
            return False
        for key, nested in value.items():
            if _contains_crossing_key(key) and _crossing_value_exists(nested):
                return True
            if inspect(nested):
                return True
        return False

    evidence = line.get("evidence")
    if inspect(evidence):
        return True
    return any(
        inspect(issue)
        or (
            _contains_crossing_key(issue.get("code"))
            and _crossing_value_exists(issue.get("message"))
        )
        for issue in line_validation_issues(line)
    )


def crossing_is_resolved(line: Mapping[str, Any]) -> bool:
    resolution = str(
        line.get("connection_review_resolution")
        or line.get("crossing_resolution")
        or ""
    ).upper()
    return resolution in {"CONNECTED", "CROSSING_ONLY"}


def unresolved_crossing(line: Mapping[str, Any]) -> bool:
    return has_crossing_evidence(line) and not crossing_is_resolved(line)


def line_id(line: Mapping[str, Any]) -> str:
    return str(line.get("line_id", line.get("id", "")))


def issue_identifier(issue: Mapping[str, Any]) -> str:
    for key in ("id", "issue_id", "line_id", "node_id"):
        value = issue.get(key)
        if value is not None and str(value).strip():
            return str(value)
    return ""


def issue_component_ids(issue: Mapping[str, Any]) -> set[str]:
    raw = issue.get("component_ids")
    if not isinstance(raw, (list, tuple, set)):
        return set()
    return {str(value) for value in raw if str(value).strip()}


def related_line_ids(
    issue: Mapping[str, Any],
    lines: Iterable[Mapping[str, Any]],
) -> set[str]:
    active = active_connection_lines(lines)
    active_by_id = {line_id(line): line for line in active if line_id(line)}
    direct_id = issue.get("line_id")
    if direct_id is not None and str(direct_id) in active_by_id:
        return {str(direct_id)}

    identifier = issue_identifier(issue)
    if identifier in active_by_id:
        return {identifier}

    components = issue_component_ids(issue)
    if not components:
        return set()
    return {
        line_id(line)
        for line in active
        if line_id(line)
        and components.intersection(
            {str(value) for value in line.get("connected_to", [])}
        )
    }


def connection_exception_line_ids(
    lines: Iterable[Mapping[str, Any]],
    topology_issues: Iterable[Mapping[str, Any]],
) -> set[str]:
    active = active_connection_lines(lines)
    ids = {
        line_id(line)
        for line in active
        if line_id(line)
        and (
            _status(line) == "AMBIGUOUS"
            or line_has_critical_issue(line)
            or unresolved_crossing(line)
        )
    }
    for issue in topology_issues:
        if is_error_issue(issue):
            ids.update(related_line_ids(issue, active))
    return ids


def connection_blockers(
    lines: Iterable[Mapping[str, Any]],
    topology_issues: Iterable[Mapping[str, Any]],
) -> list[str]:
    active = active_connection_lines(lines)
    issues = list(topology_issues)
    if not active:
        return [CONNECTION_NO_ACTIVE_MESSAGE]

    blockers: list[str] = []
    ambiguous_count = sum(1 for line in active if _status(line) == "AMBIGUOUS")
    if ambiguous_count:
        blockers.append(f"연결 대상이 불확실한 선로 {ambiguous_count}개가 있습니다.")

    crossing_count = sum(1 for line in active if unresolved_crossing(line))
    if crossing_count:
        blockers.append(f"교차 여부 확인이 필요한 선로 {crossing_count}개가 있습니다.")

    critical_line_count = sum(1 for line in active if line_has_critical_issue(line))
    critical_topology_count = sum(1 for issue in issues if is_error_issue(issue))
    if critical_line_count or critical_topology_count:
        total = max(critical_line_count, critical_topology_count)
        blockers.append(f"전기적 연결 오류 {total}건을 해결해야 합니다.")
    return blockers


def connection_has_blockers(
    lines: Iterable[Mapping[str, Any]],
    topology_issues: Iterable[Mapping[str, Any]],
) -> bool:
    return bool(connection_blockers(lines, topology_issues))


__all__ = [
    "CONNECTION_NO_ACTIVE_MESSAGE",
    "active_connection_lines",
    "connection_blockers",
    "connection_exception_line_ids",
    "connection_has_blockers",
    "crossing_is_resolved",
    "has_crossing_evidence",
    "issue_identifier",
    "is_error_issue",
    "line_has_critical_issue",
    "line_id",
    "line_validation_issues",
    "related_line_ids",
    "unresolved_crossing",
]

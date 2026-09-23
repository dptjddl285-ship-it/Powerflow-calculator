"""Shared deterministic Bus Mapping review predicates.

The proactive summary, local chat guidance, and Bus Gate must agree about
which Bus nodes are active and which active nodes still need review.
"""

from __future__ import annotations

from collections import Counter
from typing import Any, Dict, Iterable, List


BUS_NO_ACTIVE_MESSAGE = "유효한 모선(Bus) 객체가 없습니다. 객체 검수를 확인해주세요."


def _first_value(node: Dict[str, Any], *keys: str, default: Any = None) -> Any:
    for key in keys:
        if key in node:
            return node[key]
    return default


def _bus_class(node: Dict[str, Any]) -> str:
    return str(_first_value(node, "class", "className", "class_name", default="")).lower()


def _review_status(node: Dict[str, Any]) -> str:
    values = [node.get(key) for key in ("review_status", "reviewStatus", "status")]
    if any(str(value or "").upper() == "REJECTED" for value in values):
        return "REJECTED"
    for value in values:
        if value is not None and str(value).strip():
            return str(value).upper()
    return ""


def _bus_number(node: Dict[str, Any]) -> Any:
    return _first_value(node, "bus_number", "busNumber")


def _bus_number_status(node: Dict[str, Any]) -> str:
    return str(
        _first_value(node, "bus_number_status", "busNumberStatus", default="")
    ).upper()


def _bus_number_reasons(node: Dict[str, Any]) -> List[str]:
    raw = _first_value(node, "bus_number_reasons", "busNumberReasons", default=[])
    if isinstance(raw, list):
        return [str(reason) for reason in raw]
    return [str(raw)] if raw else []


def get_active_bus_nodes(nodes: Iterable[Dict[str, Any]] | None) -> List[Dict[str, Any]]:
    """Return Bus nodes that participate in Bus Mapping review.

    REJECTED nodes are intentionally excluded from totals, issue counts, and
    focus targets, matching ``review_verify_bus_gate`` and the frontend gate.
    """

    return [
        node
        for node in (nodes or [])
        if _bus_class(node) == "bus" and _review_status(node) != "REJECTED"
    ]


def evaluate_bus_mapping(nodes: Iterable[Dict[str, Any]] | None) -> Dict[str, Any]:
    """Evaluate active Bus numbers using the canonical issue predicate."""

    buses = get_active_bus_nodes(nodes)
    valid_numbers = [
        _bus_number(node)
        for node in buses
        if type(_bus_number(node)) is int and _bus_number(node) > 0
    ]
    duplicate_numbers = {
        number
        for number, count in Counter(valid_numbers).items()
        if count > 1
    }

    issue_nodes: List[Dict[str, Any]] = []
    issue_reasons: Dict[str, List[str]] = {}
    for node in buses:
        node_id = str(node.get("id", ""))
        number = _bus_number(node)
        reasons = _bus_number_reasons(node)
        has_active_duplicate_reason = any(
            reason.upper().startswith("DUPLICATE_BUS_NUMBER_")
            for reason in reasons
        )
        node_reasons: List[str] = []

        if number is None:
            node_reasons.append("MISSING_BUS_NUMBER")
        elif type(number) is not int or number <= 0:
            node_reasons.append("INVALID_BUS_NUMBER")
        elif number in duplicate_numbers:
            node_reasons.append("DUPLICATE_BUS_NUMBER")
        if _bus_number_status(node) == "UNCERTAIN":
            node_reasons.append("UNCERTAIN_BUS_NUMBER")
        if has_active_duplicate_reason:
            node_reasons.append("ACTIVE_DUPLICATE_REASON")

        if node_reasons:
            issue_nodes.append(node)
            issue_reasons[node_id] = node_reasons

    return {
        "buses": buses,
        "duplicates": duplicate_numbers,
        "issues": issue_nodes,
        "issue_ids": [str(node.get("id", "")) for node in issue_nodes],
        "issue_reasons": issue_reasons,
        "total": len(buses),
        "issue_count": len(issue_nodes),
        "verified_count": len(buses) - len(issue_nodes),
    }


__all__ = [
    "BUS_NO_ACTIVE_MESSAGE",
    "evaluate_bus_mapping",
    "get_active_bus_nodes",
]

"""Deterministic preflight for the authoritative AC power-flow solver."""

from __future__ import annotations

import math
from typing import Any, Dict, List

from core.power_flow_solver import PowerFlowSolver


def evaluate_power_flow_readiness(
    elements: Any,
    *,
    s_base: float = 100.0,
) -> Dict[str, Any]:
    blockers: List[str] = []
    if not isinstance(elements, list):
        return {"ready": False, "blockers": ["elements는 배열이어야 합니다."]}
    try:
        normalized_s_base = float(s_base)
    except (TypeError, ValueError):
        normalized_s_base = math.nan
    if not math.isfinite(normalized_s_base) or normalized_s_base <= 0:
        return {"ready": False, "blockers": ["Sbase는 0보다 큰 유한한 값이어야 합니다."]}

    solver = PowerFlowSolver(s_base=normalized_s_base, tol=1e-4, max_iter=30)
    parsed = solver.parse_elements(elements)
    blockers.extend(parsed.get("validation_errors", []))
    buses = parsed.get("buses", {})
    if not buses:
        blockers.append("계산할 유효 모선이 없습니다.")
        return _report(blockers)

    raw_buses = [
        element for element in elements
        if str(element.get("type", "")).lower() in ("bus", "tool.bus")
    ]
    if len(raw_buses) != len(buses):
        blockers.append("모선 번호가 없거나 중복되어 모선을 고유하게 식별할 수 없습니다.")

    bus_by_id = {
        str(bus.get("element_id", "")): number
        for number, bus in buses.items()
    }
    for element in raw_buses:
        if element.get("verifiedClass") and not _has_number(
            element, "bus_number", "busNumber"
        ):
            blockers.append(
                f"{_name(element)}: 검증된 모선의 구조화된 bus_number가 없습니다."
            )

    slack_bus_numbers = set()
    slack_generator_count_by_bus: Dict[int, int] = {}
    for number, bus in buses.items():
        raw = next(
            (item for item in raw_buses if str(item.get("id", "")) == bus["element_id"]),
            {},
        )
        bus_type = str(
            raw.get("bus_type") or raw.get("busType") or raw.get("type_code") or ""
        ).strip().upper()
        if raw.get("isSlack") is True or raw.get("is_slack") is True or bus_type in (
            "SLACK", "SWING", "3", "3.0"
        ):
            slack_bus_numbers.add(number)

    raw_generators = [
        element for element in elements
        if "gen" in str(element.get("type", "")).lower()
    ]
    for number, generators in parsed.get("gens_by_bus", {}).items():
        for generator in generators:
            if generator.get("is_slack"):
                slack_bus_numbers.add(number)
                slack_generator_count_by_bus[number] = (
                    slack_generator_count_by_bus.get(number, 0) + 1
                )

    if len(slack_bus_numbers) != 1:
        blockers.append(
            "명시된 Slack 설정이 없습니다."
            if not slack_bus_numbers
            else "Slack 설정은 정확히 하나의 모선에 지정해야 합니다."
        )
    if any(count > 1 for count in slack_generator_count_by_bus.values()):
        blockers.append("한 모선에 Slack 발전기가 둘 이상 지정되었습니다.")

    for generator in raw_generators:
        bus_number = _device_bus_number(generator, bus_by_id)
        if bus_number is None or bus_number not in buses:
            continue  # parse_elements already reports the invalid reference.
        required = ["vPu"]
        if not (generator.get("isSlack") or generator.get("is_slack")) and not (
            generator.get("isSynchronousCondenser")
            or generator.get("is_synchronous_condenser")
        ):
            required.append("pPu")
        _require_parameters(generator, required, blockers)

    raw_loads = [
        element for element in elements
        if "load" in str(element.get("type", "")).lower()
    ]
    for load in raw_loads:
        bus_number = _device_bus_number(load, bus_by_id)
        if bus_number is None or bus_number not in buses:
            continue  # parse_elements already reports the invalid reference.
        _require_parameters(load, ["pPu", "qPu"], blockers)

    for number, bus in buses.items():
        raw = next(
            (item for item in raw_buses if str(item.get("id", "")) == bus["element_id"]),
            {},
        )
        if number in slack_bus_numbers and not any(
            _device_bus_number(generator, bus_by_id) == number
            and (generator.get("isSlack") or generator.get("is_slack"))
            for generator in raw_generators
        ):
            _require_parameters(raw, ["vPu"], blockers)
        if number not in parsed.get("loads_by_bus", {}) and any(
            abs(_float_value(raw, field) or 0.0) > 0
            for field in ("pPu", "p_pu", "p_mw", "qPu", "q_pu", "q_mvar")
        ):
            _require_parameters(raw, ["pPu", "qPu"], blockers)

    raw_by_id = {str(element.get("id", "")): element for element in elements}
    transformer_ids = {
        str(element.get("id", ""))
        for element in elements
        if "trans" in str(element.get("type", "")).lower()
    }
    terminal_ids = {
        str(element.get("id", ""))
        for element in elements
        if any(kind in str(element.get("type", "")).lower() for kind in ("gen", "load"))
    } | transformer_ids
    for element in elements:
        element_type = str(element.get("type", "")).lower()
        if "trans" in element_type:
            _require_parameters(element, ["rPu", "xPu", "bPu", "tapRatio"], blockers)
            continue
        if not ("line" in element_type or "branch" in element_type):
            continue
        if (
            element.get("electricalBranch") is False
            or element.get("electrical_branch") is False
            or element.get("isEquipmentLead")
            or element.get("is_equipment_lead")
            or element.get("isGenLead")
            or element.get("is_gen_lead")
            or element.get("isTransformerLead")
            or element.get("is_transformer_lead")
            or "lead" in str(element.get("id", "")).lower()
        ):
            continue
        start_id = str(element.get("startElementId") or element.get("start_element_id") or "")
        end_id = str(element.get("endElementId") or element.get("end_element_id") or "")
        connected = {str(item) for item in element.get("connected_to", [])}
        if start_id in terminal_ids or end_id in terminal_ids or connected & terminal_ids:
            continue
        label = str(element.get("label", ""))
        if "↔" in label and any(marker in label.lower() for marker in ("g_", "load_")):
            continue
        required_fields = ["rPu", "xPu", "bPu"]
        missing_fields = element.get("parameterMissingFields") or []
        manual_fields = element.get("parameterInputFields") or []
        if "tapRatio" in missing_fields or "tapRatio" in manual_fields:
            required_fields.append("tapRatio")
        _require_parameters(element, required_fields, blockers)
        r_value = _float_value(element, "rPu", "r_pu")
        x_value = _float_value(element, "xPu", "x_pu")
        if r_value is not None and x_value is not None and abs(r_value) < 1e-9 and abs(x_value) < 1e-9:
            blockers.append(f"{_name(element)}: R/X 직렬 임피던스가 0입니다.")

    branches = parsed.get("branches", [])
    if not branches:
        blockers.append("유효한 선로 또는 변압기 branch가 없습니다.")

    adjacency = {number: set() for number in buses}
    for branch in branches:
        from_bus, to_bus = branch["from_bus"], branch["to_bus"]
        adjacency[from_bus].add(to_bus)
        adjacency[to_bus].add(from_bus)
        raw = raw_by_id.get(branch.get("element_id", ""), {})
        required = ["rPu", "xPu", "bPu"]
        if branch.get("is_transformer"):
            required.append("tapRatio")
        _require_parameters(raw, required, blockers)
        r_value = _float_value(raw, "rPu", "r_pu")
        x_value = _float_value(raw, "xPu", "x_pu")
        if r_value is not None and x_value is not None and abs(r_value) < 1e-9 and abs(x_value) < 1e-9:
            blockers.append(f"{branch.get('label', 'Branch')}: R/X 직렬 임피던스가 0입니다.")
        if branch.get("is_transformer"):
            tap_value = _float_value(raw, "tapRatio", "tap_ratio", "tap")
            if tap_value is not None and tap_value <= 0:
                blockers.append(f"{branch.get('label', 'Transformer')}: Tap은 0보다 커야 합니다.")

    if len(slack_bus_numbers) == 1 and branches:
        start = next(iter(slack_bus_numbers))
        visited = {start}
        queue = [start]
        while queue:
            for neighbor in adjacency.get(queue.pop(0), set()):
                if neighbor not in visited:
                    visited.add(neighbor)
                    queue.append(neighbor)
        disconnected = sorted(set(buses) - visited)
        if disconnected:
            blockers.append(f"Slack 모선에서 분리된 모선이 있습니다: {disconnected}.")

    return _report(blockers)


def _require_parameters(
    element: Dict[str, Any], fields: List[str], blockers: List[str]
) -> None:
    name = _name(element)
    status = str(element.get("parameterStatus") or element.get("parameter_status") or "").upper()
    missing = element.get("parameterMissingFields") or element.get("parameter_missing_fields") or []
    manual_fields = set(element.get("parameterInputFields") or element.get("parameter_input_fields") or [])
    missing_fields = {str(field) for field in missing}
    for field in fields:
        aliases = {
            "pPu": ("pPu", "p_pu", "p_mw"),
            "qPu": ("qPu", "q_pu", "q_mvar"),
            "vPu": ("vPu", "v_pu"),
            "rPu": ("rPu", "r_pu"),
            "xPu": ("xPu", "x_pu"),
            "bPu": ("bPu", "b_pu"),
            "tapRatio": ("tapRatio", "tap_ratio", "tap"),
        }[field]
        value = _float_value(element, *aliases)
        if value is None:
            blockers.append(f"{name}: 필수 제원 {field} 값이 없습니다.")
        else:
            excel_field = (
                status == "VALID" and not missing_fields
            ) or (
                status == "MISSING"
                and bool(missing_fields)
                and field not in missing_fields
            )
            if not excel_field and field not in manual_fields:
                blockers.append(
                    f"{name}: {field} 값의 Excel 원본 또는 사용자 입력 근거가 없습니다."
                )


def _device_bus_number(element: Dict[str, Any], bus_by_id: Dict[str, int]):
    number = element.get("bus_number") or element.get("connected_bus_number")
    if number is not None:
        try:
            return int(number)
        except (ValueError, TypeError):
            return None
    parent = element.get("parentBusId") or element.get("parent_bus_id")
    if parent is None:
        return None
    return bus_by_id.get(str(parent))


def _has_number(element: Dict[str, Any], *keys: str) -> bool:
    return any(element.get(key) is not None for key in keys)


def _float_value(element: Dict[str, Any], *keys: str):
    for key in keys:
        value = element.get(key)
        if value is None:
            continue
        try:
            parsed = float(value)
        except (ValueError, TypeError):
            continue
        if math.isfinite(parsed):
            return parsed
    return None


def _name(element: Dict[str, Any]) -> str:
    return str(element.get("label") or element.get("id") or "요소")


def _report(blockers: List[str]) -> Dict[str, Any]:
    unique = list(dict.fromkeys(blockers))
    return {"ready": not unique, "blockers": unique}

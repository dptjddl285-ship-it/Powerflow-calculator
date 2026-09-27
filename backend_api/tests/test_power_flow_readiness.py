from __future__ import annotations

from pathlib import Path
import sys

import pytest

backend_dir = Path(__file__).resolve().parent.parent
if str(backend_dir) not in sys.path:
    sys.path.insert(0, str(backend_dir))

from core.power_flow_readiness import evaluate_power_flow_readiness
from agent.providers import GeminiReviewAssistantProvider, LocalReviewAssistantProvider


def _manual_case(*, extra_buses: int = 0):
    elements = [
        {
            "id": "bus_1",
            "type": "bus",
            "label": "Bus 1",
            "bus_number": 1,
            "isSlack": True,
            "vPu": 1.0,
            "parameterInputFields": ["vPu"],
        },
        {
            "id": "bus_2",
            "type": "bus",
            "label": "Bus 2",
            "bus_number": 2,
        },
        {
            "id": "line_1_2",
            "type": "line",
            "label": "Line 1-2",
            "from_bus": 1,
            "to_bus": 2,
            "rPu": 0.01,
            "xPu": 0.1,
            "bPu": 0.0,
            "parameterInputFields": ["rPu", "xPu", "bPu"],
        },
    ]
    for number in range(3, 3 + extra_buses):
        elements.append(
            {
                "id": f"bus_{number}",
                "type": "bus",
                "label": f"Bus {number}",
                "bus_number": number,
            }
        )
    return elements


def test_manual_complete_case_is_ready_without_excel():
    report = evaluate_power_flow_readiness(_manual_case())
    assert report["ready"] is True
    assert report["blockers"] == []


def test_slack_must_be_explicit():
    elements = _manual_case()
    elements[0]["isSlack"] = False
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is False
    assert any("Slack" in blocker for blocker in report["blockers"])


def test_exactly_one_slack_bus_is_required():
    elements = _manual_case()
    elements[1].update({"isSlack": True, "vPu": 1.0, "parameterInputFields": ["vPu"]})
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is False
    assert any("정확히 하나" in blocker for blocker in report["blockers"])


def test_duplicate_slack_generators_on_same_bus_are_rejected():
    elements = _manual_case()
    for identifier in ("gen_a", "gen_b"):
        elements.append(
            {
                "id": identifier,
                "type": "generator",
                "parentBusId": "bus_1",
                "isSlack": True,
                "vPu": 1.0,
                "parameterInputFields": ["vPu"],
            }
        )
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is False
    assert any("Slack 발전기" in blocker for blocker in report["blockers"])


def test_zero_b_without_source_or_manual_input_is_not_accepted():
    elements = _manual_case()
    elements[2]["parameterInputFields"].remove("bPu")
    elements[2].update({"parameterStatus": "MISSING", "parameterMissingFields": ["bPu"]})
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is False
    assert any("bPu" in blocker for blocker in report["blockers"])


def test_explicit_manual_zero_b_is_accepted():
    elements = _manual_case()
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is True


def test_missing_line_resistance_is_rejected():
    elements = _manual_case()
    elements[2]["rPu"] = None
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is False
    assert any("rPu" in blocker for blocker in report["blockers"])


def test_zero_series_impedance_is_rejected():
    elements = _manual_case()
    elements[2].update({"rPu": 0.0, "xPu": 0.0})
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is False
    assert any("직렬 임피던스" in blocker for blocker in report["blockers"])


def test_load_requires_both_real_p_and_q_inputs():
    elements = _manual_case()
    elements.append(
        {
            "id": "load_2",
            "type": "load",
            "parentBusId": "bus_2",
            "pPu": 0.2,
            "qPu": 0.0,
            "parameterInputFields": ["pPu"],
        }
    )
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is False
    assert any("qPu" in blocker for blocker in report["blockers"])


def test_pv_generator_requires_real_p_and_voltage_but_not_q_input():
    elements = _manual_case()
    elements.append(
        {
            "id": "gen_2",
            "type": "generator",
            "parentBusId": "bus_2",
            "isSlack": False,
            "pPu": 0.2,
            "qPu": None,
            "vPu": 1.02,
            "parameterStatus": "MISSING",
            "parameterMissingFields": ["qPu"],
        }
    )
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is True, report["blockers"]


def test_transformer_tap_must_have_real_provenance():
    elements = _manual_case()
    elements[2]["type"] = "transformer"
    elements[2].update(
        {
            "tapRatio": 1.0,
            "parameterStatus": "MISSING",
            "parameterMissingFields": ["tapRatio"],
        }
    )
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is False
    assert any("tapRatio" in blocker for blocker in report["blockers"])


def test_disconnected_bus_topology_is_rejected():
    report = evaluate_power_flow_readiness(_manual_case(extra_buses=1))
    assert report["ready"] is False
    assert any("분리된 모선" in blocker for blocker in report["blockers"])


def test_line_with_invalid_bus_endpoint_is_rejected():
    elements = _manual_case()
    elements[2]["to_bus"] = 99
    report = evaluate_power_flow_readiness(elements)
    assert report["ready"] is False
    assert any("valid buses" in blocker or "branch" in blocker.lower() for blocker in report["blockers"])


@pytest.mark.parametrize("s_base", [0, -100, float("nan"), float("inf")])
def test_invalid_sbase_is_rejected(s_base):
    report = evaluate_power_flow_readiness(_manual_case(), s_base=s_base)
    assert report["ready"] is False
    assert any("Sbase" in blocker for blocker in report["blockers"])


def test_lensy_summary_uses_actual_converged_solver_evidence_without_threshold_labels():
    context = {
        "powerflow_evidence": {
            "converged": True,
            "iterations": 4,
            "max_mismatch": 0.00001,
            "lowest_voltage": {"bus": 2, "voltage_pu": 0.98},
            "largest_absolute_line_flow": {
                "from_bus": 1,
                "to_bus": 2,
                "p_from_mw": -45.2,
            },
        }
    }
    result = LocalReviewAssistantProvider().generate_proactive_summary(
        document_id="test",
        stage="POWERFLOW_CONVERGED",
        app_context=context,
    )
    text = result["reply_ko"] + result["summary_text"]
    assert "4회 반복" in text
    assert "0.98 pu" in text
    assert "-45.2 MW" in text
    assert not any(label in text for label in ("저전압 위험", "과부하", "위험 판정"))


def test_lensy_never_calls_nonconverged_solver_result_success():
    context = {
        "powerflow_evidence": {
            "converged": False,
            "iterations": 30,
            "max_mismatch": 0.03,
        }
    }
    provider = GeminiReviewAssistantProvider(api_key="test-only")
    result = provider.generate_proactive_summary(
        document_id="test",
        stage="POWERFLOW_NOT_CONVERGED",
        app_context=context,
    )
    text = result["reply_ko"] + result["summary_text"]
    assert "미수렴" in text
    assert "30회 반복" in text
    assert "수렴했습니다" not in text
    assert result["agent_status"] == "LOCAL_POWERFLOW_CONTRACT"

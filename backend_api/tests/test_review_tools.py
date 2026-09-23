from __future__ import annotations

from pathlib import Path
import sys

import cv2
import numpy as np
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient


BACKEND = Path(__file__).resolve().parents[1]
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from agent_tools.vision_tools import (  # noqa: E402
    _match_candidates,
    _split_cross_class_conflicts,
    configure_review_tools,
)
from review.api import router  # noqa: E402
from review.store import review_store  # noqa: E402
from review.vision_adapter import build_graph_document  # noqa: E402


def source_image_bytes() -> bytes:
    image = np.full((480, 640, 3), 255, np.uint8)
    cv2.line(image, (40, 80), (160, 80), (0, 0, 0), 3)
    cv2.line(image, (100, 84), (100, 133), (0, 0, 0), 1)
    ok, encoded = cv2.imencode(".png", image)
    assert ok
    return encoded.tobytes()


def disconnected_result(*, isolated_bus: bool = False) -> dict:
    nodes = [{
        "id": "bus_0",
        "class": "bus",
        "bbox": [100.0, 80.0, 120.0, 8.0],
        "confidence": 0.95,
        "source": "cv_primary",
    }]
    if not isolated_bus:
        nodes.append({
            "id": "load_1",
            "class": "load",
            "bbox": [100.0, 145.0, 18.0, 24.0],
            "confidence": 0.91,
            "source": "cv_primary",
        })
    issue_node = "bus_0" if isolated_bus else "load_1"
    issue_code = "isolated_bus" if isolated_bus else "invalid_terminal_degree"
    return {
        "nodes": nodes,
        "lines": [],
        "pipeline": {
            "version": "2.0",
            "status": "needs_review",
            "image_profile": {"width": 640, "height": 480},
            "node_decisions": [
                {"id": node["id"], "state": "accept"} for node in nodes
            ],
            "graph_issues": [{
                "severity": "error" if not isolated_bus else "warning",
                "code": issue_code,
                "message": issue_code,
                "component_ids": [issue_node],
            }],
            "retry_plan": [],
        },
    }


def port_retry_result() -> dict:
    result = disconnected_result()
    result["lines"] = [{
        "line_id": "retry_L0",
        "connected_to": ["bus_0", "load_1"],
        "path": [[100, 84], [100, 133]],
        "source_port": {"side": "bottom", "score": 0.95},
        "target_port": {"side": "tail", "score": 0.92},
        "trace_method": "electrical_graph",
    }]
    result["pipeline"]["graph_issues"] = []
    return result


def roi_retry_result() -> dict:
    return {
        "nodes": [
            {
                "id": "bus_local",
                "class": "bus",
                "bbox": [100.0, 80.0, 120.0, 8.0],
                "confidence": 0.95,
                "source": "cv_primary",
            },
            {
                "id": "generator_local",
                "class": "generator",
                "bbox": [100.0, 155.0, 36.0, 36.0],
                "confidence": 0.88,
                "source": "yolo_generator_symbol",
            },
        ],
        "lines": [{
            "line_id": "roi_L0",
            "connected_to": ["bus_local", "generator_local"],
            "path": [[100, 84], [100, 137]],
            "source_port": {"side": "bottom"},
            "target_port": {"side": "top"},
            "trace_method": "electrical_graph",
        }],
        "pipeline": {
            "image_profile": {"width": 280, "height": 280},
            "node_decisions": [],
            "graph_issues": [],
            "retry_plan": [],
        },
    }


@pytest.fixture(autouse=True)
def clean_store():
    review_store.clear()
    yield
    review_store.clear()


@pytest.fixture
def client() -> TestClient:
    app = FastAPI()
    app.include_router(router)
    return TestClient(app)


def register_analysis(client: TestClient, result: dict) -> dict:
    image_bytes = source_image_bytes()
    document = build_graph_document(
        result,
        image_bytes=image_bytes,
        filename="TEST_TOOL.png",
    )
    response = client.post("/review/documents", json=document.model_dump(mode="json"))
    assert response.status_code == 201
    review_store.put_analysis_asset(
        document.document_id,
        image_bytes=image_bytes,
        vision_result=result,
    )
    return response.json()


def test_repeated_tile_detection_matches_the_same_existing_node() -> None:
    document = build_graph_document(
        disconnected_result(isolated_bus=True),
        image_bytes=source_image_bytes(),
        filename="TEST_TOOL.png",
    )
    repeated = [
        {
            "id": "tile_0:bus_local",
            "class": "bus",
            "bbox": [100.0, 80.0, 120.0, 8.0],
        },
        {
            "id": "tile_1:bus_local",
            "class": "bus",
            "bbox": [101.0, 80.0, 119.0, 8.0],
        },
    ]

    mapping, unmatched = _match_candidates(document, repeated)

    assert set(mapping) == {"tile_0:bus_local", "tile_1:bus_local"}
    assert len(set(mapping.values())) == 1
    assert unmatched == []


def test_cross_class_overlap_is_not_proposed_as_a_missing_object() -> None:
    document = build_graph_document(
        disconnected_result(isolated_bus=True),
        image_bytes=source_image_bytes(),
        filename="TEST_TOOL.png",
    )
    overlapping_generator = [{
        "id": "generator_local",
        "class": "generator",
        "bbox": [100.0, 80.0, 100.0, 12.0],
        "confidence": 0.86,
    }]

    missing, conflicts = _split_cross_class_conflicts(
        document,
        overlapping_generator,
    )

    assert missing == []
    assert len(conflicts) == 1
    assert conflicts[0]["candidate_class"] == "generator"
    assert conflicts[0]["existing_class"] == "bus"


def test_port_retry_returns_preview_and_applies_only_after_approval(
    client: TestClient,
) -> None:
    configure_review_tools(lambda image_bytes: port_retry_result())
    document = register_analysis(client, disconnected_result())
    document_id = document["document_id"]
    issue_id = document["issues"][0]["issue_id"]

    retry = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/retry",
        json={"tool": "auto"},
    )
    assert retry.status_code == 201
    preview = retry.json()
    assert preview["tool_name"] == "port_aware_retry"
    assert preview["status"] == "PENDING"
    assert [item["operation"] for item in preview["operations"]] == ["add_edge"]

    unchanged = client.get(f"/review/documents/{document_id}").json()
    assert unchanged["edges"] == []
    assert unchanged["revision"] == 1

    applied = client.post(
        f"/review/documents/{document_id}/patches/{preview['patch_id']}/apply",
        json={"note": "Preview에서 실제 픽셀 경로 확인"},
    )
    assert applied.status_code == 200
    payload = applied.json()
    assert len(payload["edges"]) == 1
    assert len(payload["ports"]) == 2
    assert payload["issues"][0]["status"] == "resolved"
    assert payload["revision"] == 2
    assert payload["audit_log"][-1]["action"] == "patch_applied:port_aware_retry"

    stored_patch = client.get(
        f"/review/documents/{document_id}/patches/{preview['patch_id']}"
    ).json()
    assert stored_patch["status"] == "APPLIED"


def test_roi_retry_can_preview_missing_node_and_its_real_traced_edge(
    client: TestClient,
) -> None:
    configure_review_tools(lambda image_bytes: roi_retry_result())
    document = register_analysis(client, disconnected_result(isolated_bus=True))
    document_id = document["document_id"]
    issue_id = document["issues"][0]["issue_id"]

    retry = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/retry",
        json={"tool": "roi_reanalysis"},
    )
    assert retry.status_code == 201
    preview = retry.json()
    assert preview["status"] == "PENDING"
    assert {item["operation"] for item in preview["operations"]} == {
        "add_node",
        "add_edge",
    }
    assert client.get(f"/review/documents/{document_id}").json()["nodes"] == document["nodes"]

    applied = client.post(
        f"/review/documents/{document_id}/patches/{preview['patch_id']}/apply",
        json={},
    )
    assert applied.status_code == 200
    payload = applied.json()
    assert len(payload["nodes"]) == 2
    assert len(payload["edges"]) == 1


def test_user_roi_issue_is_created_then_reanalyzed_without_immediate_apply(
    client: TestClient,
) -> None:
    configure_review_tools(lambda image_bytes: roi_retry_result())
    document = register_analysis(client, disconnected_result(isolated_bus=True))
    document_id = document["document_id"]

    created = client.post(
        f"/review/documents/{document_id}/issues",
        json={
            "roi": {
                "x_min": 20,
                "y_min": 20,
                "x_max": 300,
                "y_max": 300,
            },
            "message": "Canvas에서 선택한 누락 후보",
        },
    )
    assert created.status_code == 201
    updated = created.json()
    assert updated["revision"] == 2
    issue = updated["issues"][-1]
    assert issue["code"] == "user_missing_component_roi"
    assert issue["component_ids"] == []
    assert issue["roi"] == {
        "x_min": 20.0,
        "y_min": 20.0,
        "x_max": 300.0,
        "y_max": 300.0,
    }

    retry = client.post(
        f"/review/documents/{document_id}/issues/{issue['issue_id']}/retry",
        json={"tool": "roi_reanalysis"},
    )
    assert retry.status_code == 201
    preview = retry.json()
    assert preview["tool_name"] == "roi_reanalysis"
    assert preview["base_revision"] == 2
    assert preview["status"] == "PENDING"

    unchanged = client.get(f"/review/documents/{document_id}").json()
    assert unchanged["revision"] == 2
    assert len(unchanged["nodes"]) == 1


def test_user_roi_issue_rejects_out_of_bounds_region(client: TestClient) -> None:
    document = register_analysis(client, disconnected_result(isolated_bus=True))
    response = client.post(
        f"/review/documents/{document['document_id']}/issues",
        json={
            "roi": {
                "x_min": 20,
                "y_min": 20,
                "x_max": 700,
                "y_max": 300,
            },
        },
    )
    assert response.status_code == 409
    assert "width" in response.json()["detail"]


def test_object_only_retry_removes_edge_operations_from_preview(
    client: TestClient,
) -> None:
    configure_review_tools(lambda image_bytes: roi_retry_result())
    document = register_analysis(client, disconnected_result(isolated_bus=True))
    document_id = document["document_id"]
    issue_id = document["issues"][0]["issue_id"]

    retry = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/retry",
        json={"tool": "auto", "object_only": True},
    )
    assert retry.status_code == 201
    preview = retry.json()
    assert preview["tool_name"] == "roi_reanalysis"
    assert [item["operation"] for item in preview["operations"]] == ["add_node"]
    assert "Object-only" in preview["summary"]


def test_missing_object_scan_returns_node_only_preview(client: TestClient) -> None:
    configure_review_tools(lambda image_bytes: roi_retry_result())
    document = register_analysis(client, disconnected_result(isolated_bus=True))
    document_id = document["document_id"]

    response = client.post(
        f"/review/documents/{document_id}/missing-object-scan",
    )
    assert response.status_code == 201
    payload = response.json()
    preview = payload["patch"]
    updated = payload["document"]
    assert preview["tool_name"] == "missing_object_scan"
    assert preview["status"] == "PENDING"
    assert preview["operations"]
    assert {item["operation"] for item in preview["operations"]} == {"add_node"}
    candidate = preview["operations"][0]["node"]
    assert candidate["parameters"]["review_candidate"]["kind"] == "missing_object"
    assert candidate["parameters"]["review_candidate"]["evidence"]
    assert updated["revision"] == 2
    assert updated["issues"][-1]["code"] == "missing_object_candidates"
    assert preview["base_revision"] == updated["revision"]

    applied = client.post(
        f"/review/documents/{document_id}/patches/{preview['patch_id']}/apply",
        json={},
    )
    assert applied.status_code == 200
    applied_document = applied.json()
    assert applied_document["edges"] == []
    original_issue = next(
        issue for issue in applied_document["issues"]
        if issue["issue_id"] == preview["issue_id"]
    )
    assert original_issue["status"] == "resolved"
    candidate_ids = {
        operation["node"]["internal_id"]
        for operation in preview["operations"]
    }
    follow_ups = [
        issue for issue in applied_document["issues"]
        if issue["code"] in {
            "suspicious_added_bus",
            "unconnected_added_candidate",
        }
    ]
    assert follow_ups
    assert all(issue["status"] == "open" for issue in follow_ups)
    assert {
        component_id
        for issue in follow_ups
        for component_id in issue["component_ids"]
    } == candidate_ids
    assert any(issue["code"] == "suspicious_added_bus" for issue in follow_ups)


def test_missing_object_scan_applies_only_selected_candidates(client: TestClient) -> None:
    configure_review_tools(lambda image_bytes: roi_retry_result())
    document = register_analysis(client, disconnected_result(isolated_bus=True))
    document_id = document["document_id"]
    payload = client.post(
        f"/review/documents/{document_id}/missing-object-scan",
    ).json()
    preview = payload["patch"]
    candidate_ids = [
        operation["node"]["internal_id"]
        for operation in preview["operations"]
    ]
    assert candidate_ids

    applied = client.post(
        f"/review/documents/{document_id}/patches/{preview['patch_id']}/apply",
        json={"selected_node_ids": [candidate_ids[0]]},
    )
    assert applied.status_code == 200
    applied_ids = {node["internal_id"] for node in applied.json()["nodes"]}
    assert candidate_ids[0] in applied_ids
    assert not (set(candidate_ids[1:]) & applied_ids)


def test_missing_object_scan_rejects_unknown_selected_candidate(
    client: TestClient,
) -> None:
    configure_review_tools(lambda image_bytes: roi_retry_result())
    document = register_analysis(client, disconnected_result(isolated_bus=True))
    document_id = document["document_id"]
    preview = client.post(
        f"/review/documents/{document_id}/missing-object-scan",
    ).json()["patch"]

    applied = client.post(
        f"/review/documents/{document_id}/patches/{preview['patch_id']}/apply",
        json={"selected_node_ids": ["not_in_this_patch"]},
    )
    assert applied.status_code == 409
    assert "not part of this patch" in applied.json()["detail"]


def test_reject_keeps_document_unchanged(client: TestClient) -> None:
    configure_review_tools(lambda image_bytes: port_retry_result())
    document = register_analysis(client, disconnected_result())
    document_id = document["document_id"]
    issue_id = document["issues"][0]["issue_id"]
    preview = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/retry",
        json={},
    ).json()

    rejected = client.post(
        f"/review/documents/{document_id}/patches/{preview['patch_id']}/reject",
        json={"note": "후보가 원본과 다름"},
    )
    assert rejected.status_code == 200
    assert rejected.json()["status"] == "REJECTED"
    current = client.get(f"/review/documents/{document_id}").json()
    assert current["revision"] == 1
    assert current["edges"] == []


def test_stale_preview_cannot_be_applied(client: TestClient) -> None:
    configure_review_tools(lambda image_bytes: port_retry_result())
    document = register_analysis(client, disconnected_result())
    document_id = document["document_id"]
    issue_id = document["issues"][0]["issue_id"]
    first = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/retry",
        json={},
    ).json()
    second = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/retry",
        json={},
    ).json()
    assert client.post(
        f"/review/documents/{document_id}/patches/{first['patch_id']}/apply",
        json={},
    ).status_code == 200

    stale = client.post(
        f"/review/documents/{document_id}/patches/{second['patch_id']}/apply",
        json={},
    )
    assert stale.status_code == 409
    assert "stale patch" in stale.json()["detail"]


def test_retry_requires_stored_source_image(client: TestClient) -> None:
    document = build_graph_document(disconnected_result(), image_bytes=b"not-stored")
    client.post("/review/documents", json=document.model_dump(mode="json"))
    issue_id = document.issues[0].issue_id

    response = client.post(
        f"/review/documents/{document.document_id}/issues/{issue_id}/retry",
        json={},
    )
    assert response.status_code == 409
    assert "source image" in response.json()["detail"]


def test_auto_agent_retries_once_then_returns_improved_preview_with_activity(
    client: TestClient,
) -> None:
    calls = 0

    def analyzer(image_bytes: bytes) -> dict:
        nonlocal calls
        del image_bytes
        calls += 1
        return disconnected_result() if calls == 1 else port_retry_result()

    configure_review_tools(analyzer)
    document = register_analysis(client, disconnected_result())
    document_id = document["document_id"]
    issue_id = document["issues"][0]["issue_id"]

    response = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/retry",
        json={"tool": "auto"},
    )
    assert response.status_code == 201
    preview = response.json()
    assert calls == 2
    assert preview["tool_name"] == "roi_reanalysis"
    assert preview["status"] == "PENDING"
    assert preview["analysis_snapshot"]["agent_attempts"] == 2
    assert [item["operation"] for item in preview["operations"]] == ["add_edge"]

    unchanged = client.get(f"/review/documents/{document_id}").json()
    assert unchanged["revision"] == document["revision"]
    assert unchanged["edges"] == []

    runs = client.get(f"/review/documents/{document_id}/agent-runs")
    assert runs.status_code == 200
    run = runs.json()[0]
    assert run["status"] == "AWAITING_APPROVAL"
    assert [step["tool_name"] for step in run["plan"]] == [
        "port_aware_retry",
        "roi_reanalysis",
    ]
    assert [item["improved"] for item in run["evaluations"]] == [False, True]
    assert run["selected_patch_id"] == preview["patch_id"]
    events = [item["event"] for item in run["activity_log"]]
    assert "retry_scheduled" in events
    assert events[-2:] == ["final_decision", "patch_registered"]


def test_auto_agent_stops_after_two_attempts_without_exposing_bad_candidate(
    client: TestClient,
) -> None:
    calls = 0

    def analyzer(image_bytes: bytes) -> dict:
        nonlocal calls
        del image_bytes
        calls += 1
        return disconnected_result()

    configure_review_tools(analyzer)
    document = register_analysis(client, disconnected_result())
    document_id = document["document_id"]
    issue_id = document["issues"][0]["issue_id"]

    response = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/retry",
        json={"tool": "auto"},
    )
    assert response.status_code == 201
    preview = response.json()
    assert calls == 2
    assert preview["status"] == "NO_CHANGE"
    assert preview["operations"] == []

    run_id = preview["analysis_snapshot"]["agent_run_id"]
    run = client.get(
        f"/review/documents/{document_id}/agent-runs/{run_id}"
    ).json()
    assert run["status"] == "NO_IMPROVEMENT"
    assert len(run["evaluations"]) == 2
    assert all(not item["improved"] for item in run["evaluations"])
    assert run["selected_patch_id"] is None

from __future__ import annotations

import os
from pathlib import Path
import sys

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient


BACKEND = Path(__file__).resolve().parents[1]
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))
os.environ.setdefault("YOLO_CONFIG_DIR", str(BACKEND / ".ultralytics"))

from review.api import router  # noqa: E402
from review.store import review_store  # noqa: E402
from review.vision_adapter import build_graph_document  # noqa: E402


def sample_result(*, issue_severity: str = "warning") -> dict:
    return {
        "nodes": [
            {
                "id": "bus_0",
                "class": "bus",
                "bbox": [100.0, 80.0, 120.0, 8.0],
                "confidence": 0.72,
                "source": "yolo_cv_raster_run",
            },
            {
                "id": "load_1",
                "class": "load",
                "bbox": [100.0, 145.0, 18.0, 24.0],
                "confidence": 0.81,
                "source": "yolo_port_rescue",
            },
        ],
        "lines": [{
            "line_id": "L0",
            "connected_to": ["bus_0", "load_1"],
            "path": [[100, 84], [100, 133]],
            "source_port": {"side": "bottom"},
            "target_port": {"side": "tail"},
            "trace_method": "electrical_graph",
        }],
        "pipeline": {
            "version": "2.0",
            "status": "needs_review",
            "image_profile": {"width": 640, "height": 480},
            "node_decisions": [
                {"id": "bus_0", "state": "rescue"},
                {"id": "load_1", "state": "rescue"},
            ],
            "graph_issues": [{
                "severity": issue_severity,
                "code": "invalid_terminal_degree",
                "message": "terminal connection needs review",
                "component_ids": ["load_1"],
            }],
            "retry_plan": ["local_port_retrace_around_unconnected_device"],
        },
    }


@pytest.fixture(autouse=True)
def clean_review_store():
    review_store.clear()
    yield
    review_store.clear()


@pytest.fixture
def client() -> TestClient:
    app = FastAPI()
    app.include_router(router)
    return TestClient(app)


def create_document(client: TestClient, *, issue_severity: str = "warning") -> dict:
    document = build_graph_document(
        sample_result(issue_severity=issue_severity),
        image_bytes=f"image-{issue_severity}".encode(),
        filename="TEST1.jpg",
    )
    response = client.post("/review/documents", json=document.model_dump(mode="json"))
    assert response.status_code == 201
    return response.json()


def test_create_list_get_and_filter_issues(client: TestClient) -> None:
    created = create_document(client)
    document_id = created["document_id"]

    listing = client.get("/review/documents")
    assert listing.status_code == 200
    assert listing.json() == [{
        "document_id": document_id,
        "revision": 1,
        "status": "IN_REVIEW",
        "filename": "TEST1.jpg",
        "node_count": 2,
        "edge_count": 1,
        "open_issue_count": 1,
        "pending_rescue_count": 2,
    }]
    fetched = client.get(f"/review/documents/{document_id}")
    assert fetched.status_code == 200
    assert fetched.json()["document_id"] == document_id
    issues = client.get(f"/review/documents/{document_id}/issues?status=open")
    assert issues.status_code == 200
    assert len(issues.json()) == 1


def test_duplicate_document_and_missing_document_return_clear_errors(
    client: TestClient,
) -> None:
    created = create_document(client)
    duplicate = client.post("/review/documents", json=created)
    assert duplicate.status_code == 409
    assert client.get("/review/documents/missing").status_code == 404


def test_verification_gate_requires_issue_and_rescue_review(client: TestClient) -> None:
    created = create_document(client)
    document_id = created["document_id"]
    issue_id = created["issues"][0]["issue_id"]

    blocked = client.post(f"/review/documents/{document_id}/verify", json={})
    assert blocked.status_code == 409
    assert "review issue" in blocked.json()["detail"]
    assert "automatic rescue" in blocked.json()["detail"]

    acknowledged = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/acknowledge",
        json={"note": "원본 이미지와 대조 완료"},
    )
    assert acknowledged.status_code == 200
    current = acknowledged.json()
    assert current["revision"] == 2
    assert current["issues"][0]["status"] == "acknowledged"
    assert current["verification"]["unresolved_issues"] == []

    for rescue in current["rescues"]:
        confirmed = client.post(
            f"/review/documents/{document_id}/rescues/{rescue['rescue_id']}/confirm",
            json={"note": "복구 픽셀과 포트 확인"},
        )
        assert confirmed.status_code == 200
        current = confirmed.json()

    verified = client.post(
        f"/review/documents/{document_id}/verify",
        json={"note": "최종 검증 완료"},
    )
    assert verified.status_code == 200
    payload = verified.json()
    assert payload["status"] == "VERIFIED"
    assert payload["verification"]["is_verified"] is True
    assert payload["verification"]["verified_by"] == "HUMAN"
    assert payload["verification"]["verified_revision"] == payload["revision"]
    assert [item["action"] for item in payload["audit_log"]] == [
        "issue_acknowledged",
        "rescue_confirmed",
        "rescue_confirmed",
        "document_verified",
    ]


def test_error_issue_cannot_be_acknowledged(client: TestClient) -> None:
    created = create_document(client, issue_severity="error")
    document_id = created["document_id"]
    issue_id = created["issues"][0]["issue_id"]

    response = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/acknowledge",
        json={},
    )
    assert response.status_code == 409
    assert "must be resolved" in response.json()["detail"]


def test_reopening_issue_invalidates_a_verified_revision(client: TestClient) -> None:
    created = create_document(client)
    document_id = created["document_id"]
    issue_id = created["issues"][0]["issue_id"]
    client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/acknowledge",
        json={},
    )
    for rescue in created["rescues"]:
        client.post(
            f"/review/documents/{document_id}/rescues/{rescue['rescue_id']}/confirm",
            json={},
        )
    assert client.post(
        f"/review/documents/{document_id}/verify",
        json={},
    ).status_code == 200

    reopened = client.post(
        f"/review/documents/{document_id}/issues/{issue_id}/reopen",
        json={"note": "재검토 필요"},
    )
    assert reopened.status_code == 200
    payload = reopened.json()
    assert payload["status"] == "IN_REVIEW"
    assert payload["verification"]["is_verified"] is False
    assert payload["verification"]["verified_revision"] is None


def test_analyze_endpoint_automatically_registers_review_document(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import main_server

    monkeypatch.setattr(
        main_server,
        "analyze_circuit_image_adaptive",
        lambda image_bytes, model: sample_result(),
    )
    client = TestClient(main_server.app)
    response = client.post(
        "/analyze_image",
        files={"file": ("TEST1.jpg", b"fake-image", "image/jpeg")},
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "success"
    graph = payload["data"]["graph_document"]

    fetched = client.get(f"/review/documents/{graph['document_id']}")
    assert fetched.status_code == 200
    assert fetched.json() == graph

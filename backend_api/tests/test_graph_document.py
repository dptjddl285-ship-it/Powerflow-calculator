from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import sys


BACKEND = Path(__file__).resolve().parents[1]
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from review.graph_document import GraphStatus, ReviewState  # noqa: E402
from review.vision_adapter import build_graph_document  # noqa: E402


def sample_result() -> dict:
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
        "lines": [
            {
                "line_id": "L0",
                "connected_to": ["bus_0", "load_1"],
                "path": [[100, 84], [100, 133]],
                "source_port": {"side": "bottom", "score": 0.95, "distance": 1.0},
                "target_port": {"side": "tail", "score": 0.91, "distance": 0.0},
                "trace_method": "electrical_graph",
            }
        ],
        "pipeline": {
            "version": "2.0",
            "status": "needs_review",
            "image_profile": {"width": 640, "height": 480},
            "processing_scale": 1.0,
            "layers": {"object_layer": "original", "topology_layer": "text_filtered"},
            "node_decisions": [
                {"id": "bus_0", "state": "rescue"},
                {"id": "load_1", "state": "rescue"},
            ],
            "graph_issues": [
                {
                    "severity": "warning",
                    "code": "invalid_transformer_degree",
                    "message": "example review warning",
                    "component_ids": ["bus_0"],
                }
            ],
            "retry_plan": ["local_port_retrace_around_unconnected_device"],
        },
    }


def test_adapter_is_stable_and_does_not_mutate_legacy_result() -> None:
    raw = sample_result()
    before = deepcopy(raw)
    first = build_graph_document(raw, image_bytes=b"same-image", filename="TEST1.jpg")
    second = build_graph_document(raw, image_bytes=b"same-image", filename="TEST1.jpg")

    assert raw == before
    assert first.document_id == second.document_id
    assert [node.internal_id for node in first.nodes] == [
        node.internal_id for node in second.nodes
    ]
    assert first.status == GraphStatus.IN_REVIEW
    assert first.revision == 1


def test_bbox_and_image_contract_use_original_center_xywh_pixels() -> None:
    document = build_graph_document(sample_result(), image_bytes=b"image")
    bus = document.nodes[0]

    assert bus.bbox.center_x == 100.0
    assert bus.bbox.center_y == 80.0
    assert bus.bbox.width == 120.0
    assert document.image_metadata.width == 640
    assert document.image_metadata.height == 480
    assert document.image_metadata.coordinate_system == "original_image_pixels_center_xywh"


def test_auto_rescue_records_source_evidence_and_remains_reviewable() -> None:
    document = build_graph_document(sample_result(), image_bytes=b"image")

    assert len(document.rescues) == 2
    assert all(node.review_state == ReviewState.AUTO_RESCUED for node in document.nodes)
    assert {item.rescue_kind for item in document.rescues} == {
        "bus_raster_reconstruction",
        "load_port_trace",
    }
    assert all(item.automatically_applied for item in document.rescues)
    assert all(item.requires_review for item in document.rescues)
    assert document.verification.is_verified is False


def test_edges_reference_stable_nodes_and_explicit_ports() -> None:
    document = build_graph_document(sample_result(), image_bytes=b"image")
    edge = document.edges[0]
    node_ids = {node.internal_id for node in document.nodes}
    port_ids = {port.port_id for port in document.ports}

    assert edge.source_node_id in node_ids
    assert edge.target_node_id in node_ids
    assert edge.source_port_id in port_ids
    assert edge.target_port_id in port_ids
    assert len(document.ports) == 2
    assert document.ports[1].side == "tail"
    assert document.nodes[0].ports == [edge.source_port_id]
    assert document.nodes[1].ports == [edge.target_port_id]


def test_adapter_preserves_string_port_sides_from_vision_pipeline() -> None:
    raw = sample_result()
    raw["lines"][0]["source_port"] = "bottom"
    raw["lines"][0]["target_port"] = "tail"

    document = build_graph_document(raw, image_bytes=b"string-port-image")

    assert [port.side for port in document.ports] == ["bottom", "tail"]


def test_thin_bus_outlier_becomes_object_review_issue() -> None:
    raw = sample_result()
    raw["nodes"] = [
        {
            "id": f"bus_{index}",
            "class": "bus",
            "bbox": [80.0 + index * 100.0, 80.0, 80.0, thickness],
            "confidence": 0.80,
            "source": "yolo_cv_electrical_bus",
        }
        for index, thickness in enumerate((10.0, 9.0, 2.0))
    ]
    raw["lines"] = []
    raw["pipeline"]["graph_issues"] = []
    raw["pipeline"]["node_decisions"] = []

    document = build_graph_document(raw, image_bytes=b"thin-bus-image")

    issue = next(
        item for item in document.issues
        if item.code == "suspicious_bus_thickness"
    )
    thin_bus = next(node for node in document.nodes if node.source_id == "bus_2")
    assert issue.component_ids == [thin_bus.internal_id]


def test_pipeline_issues_are_remapped_and_suggest_a_deterministic_tool() -> None:
    document = build_graph_document(sample_result(), image_bytes=b"image")
    issue = document.issues[0]

    assert issue.component_ids == [document.nodes[0].internal_id]
    assert issue.suggested_tools == ["port_aware_retry"]
    assert document.verification.issue_count == 1
    assert document.verification.unresolved_issues == [issue.issue_id]


def test_invalid_legacy_edge_becomes_review_issue_instead_of_fake_path() -> None:
    raw = sample_result()
    raw["lines"][0]["connected_to"] = ["bus_0", "missing_node"]
    document = build_graph_document(raw, image_bytes=b"image")

    assert document.edges == []
    assert any(issue.code == "adapter_unknown_endpoint" for issue in document.issues)
    assert document.verification.critical_issue_count == 1


def test_graph_document_serializes_for_fastapi_response() -> None:
    document = build_graph_document(sample_result(), image_bytes=b"image")
    payload = document.model_dump(mode="json")

    assert payload["schema_version"] == "1.0"
    assert payload["status"] == "IN_REVIEW"
    assert payload["nodes"][0]["bbox"]["center_x"] == 100.0
    assert payload["rescues"][0]["automatically_applied"] is True

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import cv2
import numpy as np


BACKEND = Path(__file__).resolve().parents[1]
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from core.pipeline_policy import (  # noqa: E402
    CandidateEvidence,
    CandidatePolicy,
    DecisionState,
    inspect_image,
    validate_graph,
)
from core.adaptive_vision_pipeline import _rescale_result  # noqa: E402


class PipelinePolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        image = np.full((360, 480, 3), 255, np.uint8)
        cv2.line(image, (40, 80), (340, 80), (0, 0, 0), 2)
        cv2.line(image, (160, 80), (160, 240), (0, 0, 0), 1)
        cls.profile = inspect_image(image)
        cls.policy = CandidatePolicy(cls.profile)

    def test_low_resolution_profile_requests_scale(self) -> None:
        self.assertTrue(self.profile.low_resolution)
        self.assertGreaterEqual(self.profile.recommended_scale, 1.25)

    def test_bus_requires_branch_and_no_endpoint_bend(self) -> None:
        accepted = self.policy.decide(CandidateEvidence(
            class_name="bus",
            bbox=(120, 80, 100, 8),
            aspect_ratio=12.5,
            straightness=0.98,
            profile_score=0.90,
            stroke_ratio=1.8,
            branch_count=2,
            endpoint_bends=0,
        ))
        bent = self.policy.decide(CandidateEvidence(
            class_name="bus",
            bbox=(120, 80, 100, 8),
            aspect_ratio=12.5,
            straightness=0.98,
            profile_score=0.90,
            stroke_ratio=1.8,
            branch_count=2,
            endpoint_bends=1,
        ))
        self.assertEqual(accepted.state, DecisionState.ACCEPT)
        self.assertEqual(bent.state, DecisionState.REJECT)

    def test_fragmented_bus_can_only_use_reason_specific_rescue(self) -> None:
        decision = self.policy.decide(CandidateEvidence(
            class_name="bus",
            bbox=(120, 80, 100, 7),
            yolo_confidence=0.60,
            aspect_ratio=14.0,
            straightness=0.88,
            profile_score=0.86,
            stroke_ratio=1.0,
            branch_count=2,
            endpoint_bends=0,
            fragmented_gap=1,
        ))
        self.assertEqual(decision.state, DecisionState.RESCUE)
        self.assertEqual(decision.rescue_kind, "fragmented_bus")

    def test_load_cannot_bypass_bus_connection(self) -> None:
        decision = self.policy.decide(CandidateEvidence(
            class_name="load",
            bbox=(100, 100, 14, 20),
            yolo_confidence=0.95,
            triangle_score=0.80,
            attached_to_bus=False,
            tail_continuity=1.0,
            lead_length=20,
        ))
        self.assertEqual(decision.state, DecisionState.REJECT)

    def test_outline_load_rescue_still_requires_cv_tail_trace(self) -> None:
        decision = self.policy.decide(CandidateEvidence(
            class_name="load",
            bbox=(100, 100, 18, 24),
            yolo_confidence=0.75,
            triangle_score=0.20,
            attached_to_bus=True,
            tail_continuity=0.95,
            lead_length=60,
            enclosed_hole=False,
            tags={"outline_yolo"},
        ))
        self.assertEqual(decision.state, DecisionState.RESCUE)
        self.assertEqual(decision.rescue_kind, "outline_load")

    def test_through_line_arrow_is_not_a_load(self) -> None:
        decision = self.policy.decide(CandidateEvidence(
            class_name="load",
            bbox=(100, 100, 18, 24),
            triangle_score=0.70,
            attached_to_bus=True,
            tail_continuity=0.95,
            lead_length=80,
            tip_continues=True,
            enclosed_hole=False,
        ))
        self.assertEqual(decision.state, DecisionState.REJECT)

    def test_transformer_pair_vetoes_generator(self) -> None:
        decision = self.policy.decide(CandidateEvidence(
            class_name="generator",
            bbox=(100, 100, 30, 30),
            yolo_confidence=0.92,
            terminal_connected=True,
            transformer_pair=True,
        ))
        self.assertEqual(decision.state, DecisionState.REJECT)

    def test_transformer_requires_pair_structure(self) -> None:
        decision = self.policy.decide(CandidateEvidence(
            class_name="transformer",
            bbox=(100, 100, 35, 52),
            yolo_confidence=0.90,
            circle_pair_score=0.85,
        ))
        self.assertEqual(decision.state, DecisionState.ACCEPT)

    def test_graph_validation_requires_one_load_connection(self) -> None:
        issues = validate_graph(
            [
                {"id": "bus_1", "class": "bus"},
                {"id": "load_1", "class": "load"},
            ],
            [],
        )
        codes = {issue.code for issue in issues}
        self.assertIn("invalid_terminal_degree", codes)
        self.assertIn("isolated_bus", codes)

    def test_adaptive_resize_restores_original_coordinates(self) -> None:
        result = _rescale_result(
            {
                "nodes": [{"id": "bus_1", "bbox": [200, 100, 80, 20]}],
                "lines": [{
                    "path": [[20, 40], [60, 80]],
                    "port_distances": {"bus_1": 10.0},
                }],
            },
            2.0,
        )
        self.assertEqual(result["nodes"][0]["bbox"], [100.0, 50.0, 40.0, 10.0])
        self.assertEqual(result["lines"][0]["path"], [[10, 20], [30, 40]])
        self.assertEqual(result["lines"][0]["port_distances"]["bus_1"], 5.0)


if __name__ == "__main__":
    unittest.main()

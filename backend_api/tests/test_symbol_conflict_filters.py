from __future__ import annotations

from pathlib import Path
import sys
import unittest

import numpy as np


BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

from core.vision_logic import (  # noqa: E402
    CV_ADD_TRANSFORMER_MIN_CONF,
    YOLO_PROBE_CONFIDENCE,
    _add_validated_load_bus_fallbacks,
    _cv_transformer_can_stand_alone,
    _extract_electrical_bus_signature,
    _generator_circle_has_external_lead,
    _make_validated_load_bus_path,
    _reconstruct_weak_ink,
    _remove_load_head_bus_candidates,
    _remove_numeric_text_components,
    _restore_inline_load_conductor,
    _secondary_bus_family_indices,
)
from cv_load_experiment import (  # noqa: E402
    LoadCandidate,
    _attachment_implied_arrow_direction,
    _has_one_sided_terminal_profile,
    _set_candidate_direction,
    _source_ink_path_within_trace_corridor,
    _valid_pendant_load,
)


class SymbolConflictFilterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.image_shape = (100, 100, 3)
        self.upward_load = LoadCandidate(
            x=80,
            y=80,
            w=40,
            h=20,
            tip=(100.0, 80.0),
            base=(100.0, 100.0),
            direction=(0, -1),
            triangle_score=0.9,
        )

    def test_arrowhead_base_is_not_a_bus(self) -> None:
        arrow_base = {
            "x": 50.0,
            "y": 49.0,
            "w": 20.0,
            "h": 5.0,
            "orientation": "horizontal",
        }
        kept = _remove_load_head_bus_candidates(
            [arrow_base],
            [self.upward_load],
            self.image_shape,
        )
        self.assertEqual(kept, [])

    def test_small_bus_away_from_load_is_preserved(self) -> None:
        small_bus = {
            "x": 50.0,
            "y": 70.0,
            "w": 20.0,
            "h": 5.0,
            "orientation": "horizontal",
        }
        kept = _remove_load_head_bus_candidates(
            [small_bus],
            [self.upward_load],
            self.image_shape,
        )
        self.assertEqual(kept, [small_bus])

    def test_real_load_tail_is_never_restored_as_a_through_lane(self) -> None:
        source = np.zeros((50, 50), dtype=np.uint8)
        source[2:46, 19:22] = 255
        topology = source.copy()
        topology[15:31, 15:31] = 0
        candidate = LoadCandidate(
            x=32,
            y=30,
            w=16,
            h=20,
            tip=(40.0, 50.0),
            base=(40.0, 30.0),
            direction=(0, 1),
            triangle_score=0.9,
        )
        restored = _restore_inline_load_conductor(
            topology,
            source,
            candidate,
            thin_width=2,
            mask_box=(15, 15, 30, 30),
        )
        self.assertEqual(restored, 0)
        self.assertEqual(topology[22, 20], 0)

    def test_separate_conductor_can_cross_a_load_display_box(self) -> None:
        source = np.zeros((50, 50), dtype=np.uint8)
        source[2:46, 16:19] = 255
        topology = source.copy()
        topology[15:31, 15:31] = 0
        candidate = LoadCandidate(
            x=48,
            y=30,
            w=16,
            h=20,
            tip=(56.0, 50.0),
            base=(56.0, 30.0),
            direction=(0, 1),
            triangle_score=0.9,
        )
        restored = _restore_inline_load_conductor(
            topology,
            source,
            candidate,
            thin_width=2,
            mask_box=(15, 15, 30, 30),
        )
        self.assertGreater(restored, 0)
        self.assertTrue(np.any(topology[22, 16:19] > 0))

    def test_validated_bent_load_path_is_reused_for_topology(self) -> None:
        candidate = LoadCandidate(
            x=32,
            y=48,
            w=16,
            h=16,
            tip=(48.0, 60.0),
            base=(40.0, 60.0),
            direction=(1, 0),
            triangle_score=0.9,
            attached_bus=0,
            attachment_path=[
                (36, 60), (30, 60), (30, 50), (30, 42), (30, 40),
            ],
        )
        path = _make_validated_load_bus_path(
            candidate,
            bus_box=(24, 20, 36, 40),
        )
        self.assertEqual(path[0], (18, 30))
        self.assertEqual(path[-1], (15, 20))
        self.assertIn((15, 25), path)

    def test_hysteresis_keeps_only_weak_ink_connected_to_strong_line(self) -> None:
        strong = np.zeros((20, 20), dtype=np.uint8)
        weak = np.zeros((20, 20), dtype=np.uint8)
        strong[2:6, 8] = 1
        weak[2:16, 8] = 1
        weak[10:15, 15] = 1
        restored = _reconstruct_weak_ink(strong, weak)
        self.assertEqual(restored[14, 8], 255)
        self.assertEqual(restored[12, 15], 0)

    def test_numeric_filter_preserves_component_owned_by_load(self) -> None:
        binary = np.zeros((60, 60), dtype=np.uint8)
        binary[10:30, 10] = 255
        binary[10, 10:15] = 255
        binary[20, 10:15] = 255
        binary[29, 10:15] = 255
        self.assertEqual(
            np.count_nonzero(_remove_numeric_text_components(binary)),
            0,
        )
        protected = np.zeros_like(binary)
        protected[18:24, 8:17] = 255
        kept = _remove_numeric_text_components(binary, protected)
        self.assertEqual(np.count_nonzero(kept), np.count_nonzero(binary))

    def test_saved_load_route_uses_only_source_skeleton_pixels(self) -> None:
        source = np.zeros((24, 24), dtype=np.uint8)
        source[4:20, 10] = 255
        permissive_trace = [(11, y) for y in range(4, 20)]
        path = _source_ink_path_within_trace_corridor(
            source,
            permissive_trace,
        )
        self.assertTrue(path)
        self.assertTrue(all(source[y, x] == 255 for x, y in path))
        self.assertTrue(all(x == 10 for x, _ in path))

    def test_cardinal_attachment_repairs_wrong_arrow_orientation(self) -> None:
        path = [(12, y) for y in range(18, 8, -1)]
        direction = _attachment_implied_arrow_direction(path, thin_width=2)
        self.assertEqual(direction, (0, 1))
        candidate = LoadCandidate(
            x=20,
            y=30,
            w=16,
            h=20,
            tip=(36.0, 40.0),
            base=(20.0, 40.0),
            direction=(1, 0),
            triangle_score=0.9,
        )
        _set_candidate_direction(candidate, direction)
        self.assertEqual(candidate.direction, (0, 1))
        self.assertEqual(candidate.base, (28.0, 30.0))
        self.assertEqual(candidate.tip, (28.0, 50.0))

    def test_validated_load_relation_survives_without_invented_path(self) -> None:
        candidate = LoadCandidate(
            x=20,
            y=20,
            w=12,
            h=12,
            tip=(30.0, 20.0),
            base=(20.0, 20.0),
            direction=(1, 0),
            triangle_score=0.9,
            attached_bus=0,
            reason="accepted: traced lead reaches CV bus",
        )
        result = _add_validated_load_bus_fallbacks(
            [],
            {"load_0": "load", "bus_0": "bus"},
            {
                "load_0": {
                    "attached_bus_id": "bus_0",
                    "attached_bus_box": (40, 40, 80, 48),
                    "load_candidate": candidate,
                },
            },
        )
        self.assertEqual(result[0]["connected_to"], ["load_0", "bus_0"])
        self.assertEqual(result[0]["path"], [])
        self.assertEqual(
            result[0]["trace_method"],
            "cv_load_bus_relation_only",
        )

    def test_high_confidence_wave_transformer_can_stand_alone(self) -> None:
        prediction = {"confidence": CV_ADD_TRANSFORMER_MIN_CONF}
        metadata = {"transformer": {"style": "wave"}}
        self.assertTrue(_cv_transformer_can_stand_alone(prediction, metadata))

    def test_circle_pair_transformer_requires_two_electrical_ports(self) -> None:
        prediction = {"confidence": 0.99}
        metadata = {"transformer": {"style": "circle_pair"}}
        self.assertFalse(_cv_transformer_can_stand_alone(prediction, metadata))

        metadata["transformer"]["electrical_two_port"] = True
        self.assertFalse(_cv_transformer_can_stand_alone(prediction, metadata))

        metadata["transformer"]["hollow_interior"] = True
        self.assertFalse(_cv_transformer_can_stand_alone(prediction, metadata))

        prediction["yolo_support"] = YOLO_PROBE_CONFIDENCE
        self.assertTrue(_cv_transformer_can_stand_alone(prediction, metadata))

    def test_generator_circle_requires_immediate_external_lead(self) -> None:
        binary = np.zeros((100, 100), dtype=np.uint8)
        # Source-scale circle [25,25,10,10] becomes a 20px box centred at
        # (50,50) in the detector's 2x binary. Draw a terminal below it.
        binary[61:78, 50] = 255
        context = {"binary": binary, "thin_width": 2}
        self.assertTrue(
            _generator_circle_has_external_lead([25, 25, 10, 10], context)
        )

    def test_standalone_generator_circle_does_not_invent_a_lead(self) -> None:
        context = {
            "binary": np.zeros((100, 100), dtype=np.uint8),
            "thin_width": 2,
        }
        self.assertFalse(
            _generator_circle_has_external_lead([25, 25, 10, 10], context)
        )

    def test_bus_signature_counts_real_perpendicular_ports(self) -> None:
        image = np.full((120, 120, 3), 255, dtype=np.uint8)
        image[58:63, 20:101] = 0
        image[20:101, 39:42] = 0
        image[30:91, 79:82] = 0
        signature = _extract_electrical_bus_signature(
            image,
            [60.0, 60.0, 90.0, 14.0],
        )
        self.assertIsNotNone(signature)
        self.assertGreaterEqual(signature["perpendicular_ports"], 2)

    def test_secondary_bus_family_requires_repetition_and_multiple_ports(self) -> None:
        def record(ratio, perpendicular=3, endpoints=1, orientation="horizontal"):
            return {
                "bus": {"orientation": orientation},
                "signature": {
                    "thickness_ratio": ratio,
                    "perpendicular_ports": perpendicular,
                    "endpoint_ports": endpoints,
                },
            }

        records = [record(1.17), record(1.17, 6), record(1.33, 2)]
        records.extend([
            record(1.55), record(1.20, 1, 1), record(1.20, 1, 0),
            record(1.75), record(1.75), record(1.88),
        ])
        self.assertEqual(
            _secondary_bus_family_indices(records, primary_thickness=2.17),
            {0, 1, 2, 4},
        )

    def test_load_is_a_one_sided_electrical_terminal(self) -> None:
        binary = np.zeros((100, 100), dtype=np.uint8)
        binary[15:46, 49:52] = 255
        candidate = LoadCandidate(
            x=45,
            y=45,
            w=10,
            h=10,
            tip=(50.0, 55.0),
            base=(50.0, 45.0),
            direction=(0, 1),
            triangle_score=0.9,
        )
        self.assertTrue(_has_one_sided_terminal_profile(binary, candidate, 2))
        binary[59:85, 49:52] = 255
        self.assertFalse(_has_one_sided_terminal_profile(binary, candidate, 2))

    def test_direct_load_feeder_is_not_rejected_only_for_length(self) -> None:
        binary = np.zeros((500, 500), dtype=np.uint8)
        candidate = LoadCandidate(
            x=245,
            y=245,
            w=10,
            h=10,
            tip=(250.0, 255.0),
            base=(250.0, 245.0),
            direction=(0, 1),
            triangle_score=0.9,
            lead_length=220,
            reason="accepted: direct lead reaches CV bus",
        )
        self.assertTrue(_valid_pendant_load(binary, candidate, 2))
        candidate.reason = "accepted: traced lead reaches CV bus"
        self.assertFalse(_valid_pendant_load(binary, candidate, 2))


if __name__ == "__main__":
    unittest.main()

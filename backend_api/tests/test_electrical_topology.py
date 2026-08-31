from __future__ import annotations

from pathlib import Path
import sys
import unittest

import numpy as np


BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

from core.electrical_topology import (  # noqa: E402
    _shortest_directional_routes,
    _true_crossing_mask,
    bridge_one_pixel_gaps,
    skeletonize_binary,
    trace_electrical_connections,
)


def port(component_id: str, side: str = "boundary") -> dict:
    return {
        "component_id": component_id,
        "side": side,
        "score": 1.0,
        "distance": 0.0,
    }


class ElectricalTopologyTest(unittest.TestCase):
    def test_bridge_only_repairs_one_pixel_aligned_gaps(self) -> None:
        binary = np.zeros((21, 21), np.uint8)
        binary[10, 4:9] = 255
        binary[10, 10:16] = 255
        restored = bridge_one_pixel_gaps(binary)
        self.assertEqual(restored[10, 9], 255)

        diagonal = np.zeros((21, 21), np.uint8)
        for point in ((4, 4), (5, 5), (7, 7), (8, 8)):
            diagonal[point[1], point[0]] = 255
        restored_diagonal = bridge_one_pixel_gaps(diagonal)
        self.assertEqual(restored_diagonal[6, 6], 255)

        two_pixel_gap = np.zeros((21, 21), np.uint8)
        two_pixel_gap[10, 4:8] = 255
        two_pixel_gap[10, 10:16] = 255
        self.assertEqual(np.count_nonzero(bridge_one_pixel_gaps(two_pixel_gap)), np.count_nonzero(two_pixel_gap))

    def test_crossing_classifier_separates_cross_from_t_junction(self) -> None:
        crossing = np.zeros((41, 41), np.uint8)
        crossing[20, 5:36] = 255
        crossing[5:36, 20] = 255
        self.assertNotEqual(_true_crossing_mask(crossing)[20, 20], 0)

        tee = np.zeros((41, 41), np.uint8)
        tee[20, 5:36] = 255
        tee[20:36, 20] = 255
        self.assertEqual(np.count_nonzero(_true_crossing_mask(tee)), 0)

    def test_two_pixel_x_cluster_is_a_crossing(self) -> None:
        crossing = np.zeros((41, 41), np.uint8)
        for offset in range(5, 36):
            crossing[offset, offset] = 255
            crossing[offset, 40 - offset] = 255
        self.assertGreater(np.count_nonzero(_true_crossing_mask(crossing)), 0)

    def test_one_pixel_conductors_survive_skeletonization(self) -> None:
        binary = np.zeros((25, 25), np.uint8)
        binary[12, 3:22] = 255
        np.fill_diagonal(binary[3:13, 3:13], 255)
        skeleton = skeletonize_binary(binary)
        self.assertTrue(np.array_equal(skeleton, binary))

    def test_thick_cross_thins_without_breaking_connectivity(self) -> None:
        binary = np.zeros((41, 41), np.uint8)
        binary[18:23, 4:37] = 255
        binary[4:37, 18:23] = 255
        skeleton = skeletonize_binary(binary)
        component_count, _ = __import__("cv2").connectedComponents(skeleton)
        self.assertEqual(component_count - 1, 1)
        self.assertLess(np.count_nonzero(skeleton), np.count_nonzero(binary))
        self.assertTrue(np.any(skeleton[3:9, 17:24]))
        self.assertTrue(np.any(skeleton[32:38, 17:24]))
        self.assertTrue(np.any(skeleton[17:24, 3:9]))
        self.assertTrue(np.any(skeleton[17:24, 32:38]))

    def test_crossing_prefers_straight_continuity(self) -> None:
        skeleton = np.zeros((41, 41), np.uint8)
        skeleton[20, 5:36] = 255
        skeleton[5:36, 20] = 255
        endpoint_components = {
            (5, 20): "bus_left",
            (35, 20): "bus_right",
            (20, 5): "bus_top",
            (20, 35): "bus_bottom",
        }
        ports = {point: port(component) for point, component in endpoint_components.items()}
        classes = {component: "bus" for component in endpoint_components.values()}
        lines = trace_electrical_connections(skeleton, endpoint_components, ports, classes)
        pairs = {frozenset(line["connected_to"]) for line in lines}
        self.assertEqual(pairs, {
            frozenset(("bus_left", "bus_right")),
            frozenset(("bus_top", "bus_bottom")),
        })

    def test_crossing_cannot_turn_even_toward_an_available_terminal(self) -> None:
        skeleton = np.zeros((41, 41), np.uint8)
        skeleton[20, 5:36] = 255
        skeleton[5:36, 20] = 255
        routes = _shortest_directional_routes(
            skeleton,
            (5, 20),
            {(35, 20), (20, 5), (20, 35)},
        )
        self.assertEqual(set(routes), {(35, 20)})

    def test_diagonal_crossing_cannot_change_diagonals(self) -> None:
        skeleton = np.zeros((41, 41), np.uint8)
        for offset in range(5, 36):
            skeleton[offset, offset] = 255
            skeleton[offset, 40 - offset] = 255
        routes = _shortest_directional_routes(
            skeleton,
            (5, 5),
            {(35, 35), (35, 5), (5, 35)},
        )
        self.assertEqual(set(routes), {(35, 35)})

    def test_shallow_diagonal_crossing_cannot_change_lanes(self) -> None:
        """Raster stair-steps must not turn a shallow X into a branch."""
        cv2 = __import__("cv2")
        skeleton = np.zeros((61, 61), np.uint8)
        cv2.line(skeleton, (5, 18), (55, 42), 255, 1)
        cv2.line(skeleton, (5, 42), (55, 18), 255, 1)
        routes = _shortest_directional_routes(
            skeleton,
            (5, 18),
            {(55, 42), (5, 42), (55, 18)},
        )
        self.assertEqual(set(routes), {(55, 42)})

    def test_one_pixel_forward_spur_does_not_block_a_real_turn(self) -> None:
        skeleton = np.zeros((31, 31), np.uint8)
        skeleton[10, 4:16] = 255
        skeleton[10:25, 14] = 255
        routes = _shortest_directional_routes(
            skeleton,
            (4, 10),
            {(14, 24)},
        )
        self.assertEqual(set(routes), {(14, 24)})

    def test_t_junction_prioritizes_straight_continuation(self) -> None:
        skeleton = np.zeros((51, 61), np.uint8)
        skeleton[25, 5:56] = 255
        skeleton[25:46, 30] = 255
        routes = _shortest_directional_routes(
            skeleton,
            (5, 25),
            {(55, 25), (30, 45)},
        )
        self.assertLess(routes[(55, 25)][1], routes[(30, 45)][1])

    def test_routed_degree_two_bend_is_allowed(self) -> None:
        skeleton = np.zeros((31, 31), np.uint8)
        skeleton[5, 5:21] = 255
        skeleton[5:21, 20] = 255
        endpoints = {(5, 5): "bus_a", (20, 20): "bus_b"}
        lines = trace_electrical_connections(
            skeleton,
            endpoints,
            {point: port(component) for point, component in endpoints.items()},
            {"bus_a": "bus", "bus_b": "bus"},
        )
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["trace_method"], "electrical_graph")

    def test_load_cannot_connect_directly_to_generator(self) -> None:
        skeleton = np.zeros((15, 31), np.uint8)
        skeleton[7, 3:28] = 255
        endpoints = {(3, 7): "load_1", (27, 7): "generator_1"}
        lines = trace_electrical_connections(
            skeleton,
            endpoints,
            {point: port(component, "tail") for point, component in endpoints.items()},
            {"load_1": "load", "generator_1": "generator"},
        )
        self.assertEqual(lines, [])

    def test_load_keeps_only_one_bus_connection(self) -> None:
        skeleton = np.zeros((31, 31), np.uint8)
        skeleton[8, 3:28] = 255
        skeleton[22, 3:28] = 255
        endpoints = {
            (3, 8): "load_1",
            (27, 8): "bus_1",
            (3, 22): "load_1",
            (27, 22): "bus_2",
        }
        lines = trace_electrical_connections(
            skeleton,
            endpoints,
            {point: port(component, "tail" if component == "load_1" else "boundary") for point, component in endpoints.items()},
            {"load_1": "load", "bus_1": "bus", "bus_2": "bus"},
        )
        self.assertEqual(len(lines), 1)

    def test_load_terminal_is_a_hard_stop_for_bus_routes(self) -> None:
        """A real load port must never become a bus-to-bus waypoint."""
        skeleton = np.zeros((21, 41), np.uint8)
        skeleton[10, 3:38] = 255
        endpoints = {
            (3, 10): "bus_left",
            (20, 10): "load_inline",
            (37, 10): "bus_right",
        }
        ports = {
            (3, 10): port("bus_left"),
            (20, 10): port("load_inline", "tail"),
            (37, 10): port("bus_right"),
        }
        lines = trace_electrical_connections(
            skeleton,
            endpoints,
            ports,
            {
                "bus_left": "bus",
                "load_inline": "load",
                "bus_right": "bus",
            },
        )
        pairs = {frozenset(line["connected_to"]) for line in lines}
        self.assertNotIn(frozenset(("bus_left", "bus_right")), pairs)
        self.assertIn(frozenset(("bus_left", "load_inline")), pairs)

    def test_transformer_keeps_two_opposite_ports(self) -> None:
        skeleton = np.zeros((41, 31), np.uint8)
        skeleton[3:16, 15] = 255
        skeleton[25:38, 15] = 255
        endpoints = {
            (15, 3): "bus_top",
            (15, 15): "transformer_1",
            (15, 25): "transformer_1",
            (15, 37): "bus_bottom",
        }
        ports = {
            (15, 3): port("bus_top"),
            (15, 15): port("transformer_1", "top"),
            (15, 25): port("transformer_1", "bottom"),
            (15, 37): port("bus_bottom"),
        }
        lines = trace_electrical_connections(
            skeleton,
            endpoints,
            ports,
            {
                "bus_top": "bus",
                "transformer_1": "transformer",
                "bus_bottom": "bus",
            },
        )
        self.assertEqual(len(lines), 2)
        self.assertEqual(
            {line["source_port"] for line in lines}
            | {line["target_port"] for line in lines},
            {"boundary", "top", "bottom"},
        )

    def test_transformer_keeps_distinct_lines_on_the_same_side(self) -> None:
        skeleton = np.zeros((31, 31), np.uint8)
        skeleton[3:16, 10] = 255
        skeleton[3:16, 20] = 255
        endpoints = {
            (10, 3): "bus_left",
            (10, 15): "transformer_1",
            (20, 3): "bus_right",
            (20, 15): "transformer_1",
        }
        ports = {
            (10, 3): port("bus_left"),
            (10, 15): port("transformer_1", "top"),
            (20, 3): port("bus_right"),
            (20, 15): port("transformer_1", "top"),
        }
        lines = trace_electrical_connections(
            skeleton,
            endpoints,
            ports,
            {
                "bus_left": "bus",
                "bus_right": "bus",
                "transformer_1": "transformer",
            },
        )
        self.assertEqual(len(lines), 2)
        self.assertEqual(
            {frozenset(line["connected_to"]) for line in lines},
            {
                frozenset(("bus_left", "transformer_1")),
                frozenset(("bus_right", "transformer_1")),
            },
        )


if __name__ == "__main__":
    unittest.main()

"""Electrical-rule topology extraction over a masked conductor skeleton.

The object detector owns geometry and ports. This module owns only physical
wire paths: it never invents a straight connection across missing pixels and
never creates or moves an object.
"""

from __future__ import annotations

import heapq
import math
from typing import Any

import cv2
import numpy as np


_OFFSETS = (
    (-1, -1), (0, -1), (1, -1),
    (-1, 0),           (1, 0),
    (-1, 1),  (0, 1),  (1, 1),
)


def _zhang_suen_thinning(binary: np.ndarray) -> np.ndarray:
    """Thin a binary drawing without requiring opencv-contrib.

    The previous fallback used a 3x3 erosion, which deletes the one-pixel
    conductors found in most single-line diagrams.  Zhang-Suen thinning
    removes only boundary pixels whose removal preserves connectivity, so an
    already-thin conductor survives unchanged.
    """
    image = (binary > 0).astype(np.uint8)
    if image.ndim != 2:
        raise ValueError("skeletonization expects one binary image channel")
    if min(image.shape) < 3:
        return (image * 255).astype(np.uint8)

    changed = True
    while changed:
        changed = False
        for first_subiteration in (True, False):
            center = image[1:-1, 1:-1]
            north = image[:-2, 1:-1]
            north_east = image[:-2, 2:]
            east = image[1:-1, 2:]
            south_east = image[2:, 2:]
            south = image[2:, 1:-1]
            south_west = image[2:, :-2]
            west = image[1:-1, :-2]
            north_west = image[:-2, :-2]
            neighbours = (
                north + north_east + east + south_east
                + south + south_west + west + north_west
            )
            ordered = (
                north, north_east, east, south_east,
                south, south_west, west, north_west, north,
            )
            transitions = np.zeros_like(center, dtype=np.uint8)
            for previous, following in zip(ordered, ordered[1:]):
                transitions += ((previous == 0) & (following == 1)).astype(np.uint8)

            if first_subiteration:
                preserve_first = (north * east * south) == 0
                preserve_second = (east * south * west) == 0
            else:
                preserve_first = (north * east * west) == 0
                preserve_second = (north * south * west) == 0

            remove = (
                (center == 1)
                & (neighbours >= 2)
                & (neighbours <= 6)
                & (transitions == 1)
                & preserve_first
                & preserve_second
            )
            if np.any(remove):
                center[remove] = 0
                changed = True

    return (image * 255).astype(np.uint8)


def skeletonize_binary(binary: np.ndarray) -> np.ndarray:
    """Return a connectivity-preserving one-pixel skeleton.

    Prefer OpenCV's optimized implementation when opencv-contrib is present,
    but keep identical functionality in the normal opencv build used by the
    application and regression environment.
    """
    ink = np.where(binary > 0, 255, 0).astype(np.uint8)
    ximgproc = getattr(cv2, "ximgproc", None)
    thinning = getattr(ximgproc, "thinning", None)
    if thinning is not None:
        thinning_type = getattr(ximgproc, "THINNING_GUOHALL", 1)
        try:
            return thinning(ink, thinningType=thinning_type)
        except cv2.error:
            # A partially installed contrib build must not make topology
            # extraction behave differently from the packaged application.
            pass
    return _zhang_suen_thinning(ink)


def bridge_one_pixel_gaps(binary: np.ndarray) -> np.ndarray:
    """Restore only a single missing pixel on an already aligned conductor.

    This is intentionally narrower than dilation or a large morphological
    close.  A pixel is restored only when ink exists exactly one pixel away on
    both sides along one of the four/diagonal line axes.
    """
    ink = np.where(binary > 0, 255, 0).astype(np.uint8)
    restored = ink.copy()
    height, width = ink.shape[:2]
    for dx, dy in ((1, 0), (0, 1), (1, 1), (1, -1)):
        x_start = max(1, dx)
        x_stop = min(width - 1, width - 1 - dx)
        y_start = max(1, dy)
        y_stop = min(height - 1, height - 1 - dy)
        if x_start >= x_stop or y_start >= y_stop:
            continue
        centre = restored[y_start:y_stop, x_start:x_stop]
        first = ink[
            y_start - dy:y_stop - dy,
            x_start - dx:x_stop - dx,
        ]
        second = ink[
            y_start + dy:y_stop + dy,
            x_start + dx:x_stop + dx,
        ]
        centre[(centre == 0) & (first > 0) & (second > 0)] = 255
    return restored


def _neighbours(skeleton: np.ndarray, point: tuple[int, int]) -> list[tuple[int, int]]:
    """Return a corner-safe 8-neighbour skeleton adjacency."""
    x, y = point
    height, width = skeleton.shape[:2]
    result = []
    for dx, dy in _OFFSETS:
        nx, ny = x + dx, y + dy
        if not (0 <= nx < width and 0 <= ny < height):
            continue
        if skeleton[ny, nx] == 0:
            continue
        if dx and dy:
            # At an orthogonal corner, the diagonal edge is redundant and
            # creates an artificial three-way junction. Preserve a true
            # diagonal only when neither orthogonal bridge pixel exists.
            if skeleton[y, nx] != 0 or skeleton[ny, x] != 0:
                continue
        result.append((nx, ny))
    return result


def _pair_is_electrically_possible(first: str, second: str) -> bool:
    """Apply circuit-level endpoint constraints before route scoring."""
    classes = {first, second}
    if "load" in classes:
        return classes == {"load", "bus"}
    if "generator" in classes:
        return bool(classes.intersection({"bus", "transformer"}))
    return classes.issubset({"bus", "transformer"})


def _turn_penalty(
    incoming: tuple[int, int],
    outgoing: tuple[int, int],
    degree: int,
    junction_contact: bool = False,
) -> float:
    if incoming == (0, 0):
        return 0.0
    first = np.asarray(incoming, dtype=float)
    second = np.asarray(outgoing, dtype=float)
    cosine = float(np.dot(first, second) / (np.linalg.norm(first) * np.linalg.norm(second)))
    angle = float(np.arccos(np.clip(cosine, -1.0, 1.0)))
    # A degree-2 turn is ordinary routed wire geometry. At a crossing or
    # branch, continuity is the stronger clue: a 90-degree jump is expensive,
    # while a straight continuation is effectively free.  A virtual lane
    # endpoint is explicitly a junction contact even when raster thinning
    # leaves only two neighbours at that exact pixel.
    if junction_contact:
        return angle * 48.0
    return angle * (32.0 if degree >= 3 else 0.18)


def _crossing_lane_graph(
    skeleton: np.ndarray,
) -> tuple[
    np.ndarray,
    np.ndarray,
    dict[tuple[int, int], tuple[tuple[int, int], ...]],
]:
    """Split four-arm junctions into direction-preserving virtual wire lanes.

    The first implementation counted connected components in a one-pixel
    ring around a dilated junction.  Anti-aliased or slightly thick lines can
    split one physical arm into several ring components, so a real crossing
    was then left as an ordinary graph node and Dijkstra was free to turn
    onto a 70-degree branch.  Grouping contacts by their angle from the
    junction centre is more stable: several raster fragments on one arm are
    treated as one lane.

    A four-arm junction is handled as a crossing only when two pairs of arms
    are genuinely opposite.  A T-junction or partially observed crossing
    keeps its ordinary branch edges, but receives a virtual edge for every
    detected straight continuation.  The virtual edges are used only for
    route selection; their endpoints remain source skeleton pixels.
    """
    ink = np.where(skeleton > 0, 255, 0).astype(np.uint8)
    junctions = np.zeros_like(ink)
    ys, xs = np.where(ink > 0)
    for y, x in zip(ys, xs):
        if len(_neighbours(ink, (int(x), int(y)))) >= 3:
            junctions[y, x] = 255
    if not np.any(junctions):
        return junctions, junctions.copy(), {}

    # A one-pixel diagonal X is often thinned into two adjacent degree-3
    # islands rather than one connected junction.  With a 3x3 dilation those
    # islands remain separate, so the crossing is mistaken for two partial
    # junctions and a route may switch lanes between them.  The 5x5 cluster is
    # still local relative to the shortest bus spacing, but joins the raster
    # fragments that belong to one physical crossing.
    kernel = np.ones((5, 5), np.uint8)
    expanded = cv2.dilate(junctions, kernel)
    zone_count, zone_labels = cv2.connectedComponents(expanded, connectivity=8)
    crossing_mask = np.zeros_like(ink)
    blocked_mask = np.zeros_like(ink)
    virtual_edges: dict[tuple[int, int], list[tuple[int, int]]] = {}

    def directional_contacts(
        zone: np.ndarray,
    ) -> list[tuple[np.ndarray, tuple[int, int]]]:
        """Group ring pixels into physical arms by angular direction."""
        # A slightly wider ring gives a stable direction even when the
        # junction itself is a one-pixel diagonal/anti-aliased cluster.
        # The wider ring is paired with the 5x5 junction cluster.  It samples
        # the stable stroke direction outside the cluster instead of relying
        # on the few diagonal pixels immediately touching its boundary.
        ring_kernel = np.ones((7, 7), np.uint8)
        outer_ring = (
            cv2.dilate(zone.astype(np.uint8), ring_kernel).astype(bool)
            & ~zone
        )
        contact_y, contact_x = np.where(outer_ring & (ink > 0))
        if len(contact_x) == 0:
            return []

        zone_y, zone_x = np.mean(np.argwhere(zone), axis=0)
        vectors = np.column_stack((
            contact_x.astype(float) - float(zone_x),
            contact_y.astype(float) - float(zone_y),
        ))
        radii = np.linalg.norm(vectors, axis=1)
        valid = radii > 1e-6
        if not np.any(valid):
            return []
        contact_x = contact_x[valid]
        contact_y = contact_y[valid]
        vectors = vectors[valid]
        radii = radii[valid]

        # Twenty-four bins are wide enough to merge raster fragments from one
        # stroke while keeping ordinary crossing arms well separated.
        bin_count = 24
        angles = np.arctan2(vectors[:, 1], vectors[:, 0])
        bins = np.floor(
            (angles + math.pi) / (2.0 * math.pi) * bin_count
        ).astype(int) % bin_count
        occupied = np.zeros(bin_count, dtype=bool)
        occupied[np.unique(bins)] = True

        # Convert occupied angular bins into circular runs.  A run is one
        # physical arm; fragments from the same arm remain in the same run.
        if np.all(occupied):
            runs = [list(range(bin_count))]
        else:
            # Start immediately after an empty bin so the circular wrap is
            # handled without treating the empty bin itself as an arm.
            first_gap = int(np.flatnonzero(~occupied)[0])
            runs = []
            current = []
            for offset in range(1, bin_count + 1):
                index = (first_gap + offset) % bin_count
                if occupied[index]:
                    current.append(index)
                elif current:
                    runs.append(current)
                    current = []
            if current:
                runs.append(current)

        contacts = []
        for run in runs:
            selected = np.isin(bins, run)
            if not np.any(selected):
                continue
            direction = np.mean(vectors[selected], axis=0)
            norm = float(np.linalg.norm(direction))
            if norm <= 1e-6:
                continue
            direction = direction / norm
            selected_indices = np.flatnonzero(selected)
            # Use the closest source pixel to the blocked zone as the virtual
            # edge endpoint. This keeps the transition attached to real ink.
            nearest_index = selected_indices[int(np.argmin(radii[selected]))]
            point = (
                int(contact_x[nearest_index]),
                int(contact_y[nearest_index]),
            )
            contacts.append((direction, point))
        return contacts

    def source_segment_supported(
        first: tuple[int, int],
        second: tuple[int, int],
    ) -> bool:
        """Check that a proposed lane has nearby source skeleton pixels."""
        distance = float(np.hypot(
            second[0] - first[0],
            second[1] - first[1],
        ))
        sample_count = max(2, int(math.ceil(distance)) + 1)
        height, width = ink.shape[:2]
        hits = 0
        for fraction in np.linspace(0.0, 1.0, sample_count):
            x = int(round(first[0] + fraction * (second[0] - first[0])))
            y = int(round(first[1] + fraction * (second[1] - first[1])))
            left = max(0, x - 2)
            right = min(width, x + 3)
            top = max(0, y - 2)
            bottom = min(height, y + 3)
            if np.any(ink[top:bottom, left:right] > 0):
                hits += 1
        return hits / float(sample_count) >= 0.72

    # A low-resolution crossing can be split into two nearby T-like zones:
    # one contains the incoming diagonal arm and the other contains the
    # outgoing diagonal arm, while a short raster corridor joins them.  If
    # those zones are processed independently, the route can enter through
    # one arm and leave through the wrong arm.  Detect this topology from
    # geometry, not from an image name or a fixed coordinate.
    zone_records: dict[
        int,
        tuple[np.ndarray, list[tuple[np.ndarray, tuple[int, int]]]],
    ] = {}
    for zone_label in range(1, zone_count):
        zone = zone_labels == zone_label
        contacts = directional_contacts(zone)
        if len(contacts) >= 3:
            zone_records[zone_label] = (zone, contacts)

    complex_zones: set[int] = set()
    zone_items = list(zone_records.items())
    for first_offset, (first_label, first_record) in enumerate(zone_items):
        first_zone, first_contacts = first_record
        first_centre_y, first_centre_x = np.mean(
            np.argwhere(first_zone),
            axis=0,
        )
        for second_label, second_record in zone_items[first_offset + 1:]:
            if first_label in complex_zones or second_label in complex_zones:
                continue
            second_zone, second_contacts = second_record
            second_centre_y, second_centre_x = np.mean(
                np.argwhere(second_zone),
                axis=0,
            )
            centre_vector = np.asarray((
                float(second_centre_x - first_centre_x),
                float(second_centre_y - first_centre_y),
            ))
            centre_distance = float(np.linalg.norm(centre_vector))
            if not 8.0 <= centre_distance <= 32.0:
                continue
            centre_vector /= centre_distance

            first_directions = [direction for direction, _ in first_contacts]
            second_directions = [direction for direction, _ in second_contacts]
            first_internal = max(
                range(len(first_directions)),
                key=lambda index: float(np.dot(
                    first_directions[index],
                    centre_vector,
                )),
            )
            second_internal = max(
                range(len(second_directions)),
                key=lambda index: float(np.dot(
                    second_directions[index],
                    -centre_vector,
                )),
            )
            first_internal_score = float(np.dot(
                first_directions[first_internal],
                centre_vector,
            ))
            second_internal_score = float(np.dot(
                second_directions[second_internal],
                -centre_vector,
            ))
            if first_internal_score < 0.55 or second_internal_score < 0.55:
                continue

            first_outer = [
                index for index in range(len(first_contacts))
                if index != first_internal
            ]
            second_outer = [
                index for index in range(len(second_contacts))
                if index != second_internal
            ]
            if len(first_outer) != 2 or len(second_outer) != 2:
                continue

            outer_pairs = []
            for first_index in first_outer:
                for second_index in second_outer:
                    cosine = float(np.dot(
                        first_directions[first_index],
                        second_directions[second_index],
                    ))
                    # A split crossing is only valid when each of its two
                    # lanes is almost collinear across the raster gap.  A
                    # looser threshold also accepts ordinary corners/T-
                    # branches as a two-lane crossing and can recreate the
                    # lane swap this pre-pass is meant to prevent.
                    if cosine <= -0.93:
                        first_point = first_contacts[first_index][1]
                        second_point = second_contacts[second_index][1]
                        if source_segment_supported(first_point, second_point):
                            outer_pairs.append((
                                cosine,
                                first_index,
                                second_index,
                            ))
            if len(outer_pairs) < 2:
                continue

            selected_outer_pairs = None
            selected_outer_score = float("inf")
            for first_pair_index, first_pair in enumerate(outer_pairs):
                for second_pair in outer_pairs[first_pair_index + 1:]:
                    if first_pair[1] == second_pair[1] or first_pair[2] == second_pair[2]:
                        continue
                    score = first_pair[0] + second_pair[0]
                    if score < selected_outer_score:
                        selected_outer_score = score
                        selected_outer_pairs = (first_pair, second_pair)
            if selected_outer_pairs is None:
                continue

            # Block both small junctions and the real ink corridor between
            # them.  The two validated opposite pairs are then the only
            # possible lanes through this split crossing.
            first_centre = (
                int(round(first_centre_x)),
                int(round(first_centre_y)),
            )
            second_centre = (
                int(round(second_centre_x)),
                int(round(second_centre_y)),
            )
            complex_pixels = (first_zone | second_zone) & (ink > 0)
            corridor = np.zeros_like(ink)
            cv2.line(corridor, first_centre, second_centre, 255, 3)
            complex_pixels |= (corridor > 0) & (ink > 0)
            crossing_mask[complex_pixels] = 255
            blocked_mask[complex_pixels] = 255
            for _, first_index, second_index in selected_outer_pairs:
                first_point = first_contacts[first_index][1]
                second_point = second_contacts[second_index][1]
                virtual_edges.setdefault(first_point, []).append(second_point)
                virtual_edges.setdefault(second_point, []).append(first_point)
            complex_zones.update((first_label, second_label))

    for zone_label in range(1, zone_count):
        if zone_label in complex_zones:
            continue
        zone = zone_labels == zone_label
        contacts = zone_records.get(zone_label, (zone, []))[1]
        if len(contacts) < 3:
            continue

        directions = [direction for direction, _ in contacts]

        opposite_pairs = []
        for first_index in range(len(directions)):
            for second_index in range(first_index + 1, len(directions)):
                cosine = float(np.dot(
                    directions[first_index],
                    directions[second_index],
                ))
                # Low-resolution diagonal crossings often expose only three
                # stable contact arms after thinning.  Keep the jump rule
                # strict enough to reject ordinary sharp branches, but allow
                # a roughly 120-degree partial crossing to recover the
                # direction-preserving lane.
                if cosine <= -0.55:
                    opposite_pairs.append((cosine, first_index, second_index))
        opposite_pairs.sort(key=lambda item: item[0])

        # Do not assume that a noisy junction has exactly four contact arms
        # or that the first four contacts are the crossing.  Search all
        # disjoint opposite-pair combinations and choose the most collinear
        # two-lane interpretation.
        selected_pairing = None
        selected_score = float("inf")
        for first_pair_index, first_pair in enumerate(opposite_pairs):
            for second_pair in opposite_pairs[first_pair_index + 1:]:
                if set(first_pair[1:]).intersection(second_pair[1:]):
                    continue
                pairing_score = first_pair[0] + second_pair[0]
                if pairing_score < selected_score:
                    selected_score = pairing_score
                    selected_pairing = (
                        (first_pair[1], first_pair[2]),
                        (second_pair[1], second_pair[2]),
                    )
        contact_points = [point for _, point in contacts]

        paired_arm_indices = (
            set(index for pair in selected_pairing for index in pair)
            if selected_pairing is not None
            else set()
        )
        # A single physical arm can still produce two contact runs when a
        # diagonal stroke is stair-stepped.  Treat those extra runs as noise
        # only when they point close to one of the four paired arms.  An
        # additional arm at a genuinely connected T/branch remains a partial
        # junction and is deliberately left open below.
        duplicate_arm_cosine = math.cos(math.radians(35.0))
        extra_contacts_are_duplicates = bool(selected_pairing) and all(
            max(
                float(np.dot(directions[index], directions[paired_index]))
                for paired_index in paired_arm_indices
            ) >= duplicate_arm_cosine
            for index in range(len(contacts))
            if index not in paired_arm_indices
        )
        complete_crossing = (
            selected_pairing is not None
            and len(paired_arm_indices) == 4
            and extra_contacts_are_duplicates
        )

        if complete_crossing:
            # A complete four-arm crossing has two independent straight
            # lanes. Block the noisy centre so a route cannot turn through
            # it, then bridge only the two source-aligned lane pairs.  The
            # same rule also covers a four-arm crossing whose rasterisation
            # yielded duplicate contact fragments on one arm.
            crossing_pixels = zone & (ink > 0)
            crossing_mask[crossing_pixels] = 255
            blocked_mask[crossing_pixels] = 255
            selected_pairs = selected_pairing
        else:
            # A T-junction or a partially observed crossing may have only one
            # opposite pair. Keep the ordinary graph open so a real branch
            # can still turn, but add a zero-turn jump edge for the opposite
            # arms. This is the useful part of the original jump logic: it
            # makes continuation win when a straight lane exists without
            # deleting a valid branch route.
            selected_pairs = []
            used_arm_indices = set()
            if selected_pairing is not None:
                # More than four contact arms usually means that nearby
                # branches were merged into one raster zone. Preserve the
                # detected opposite pairs, but do not block the whole zone.
                preferred_pairs = {
                    tuple(sorted(pair))
                    for pair in selected_pairing
                }
                opposite_pairs.sort(
                    key=lambda item: (
                        tuple(sorted(item[1:])) not in preferred_pairs,
                        item[0],
                    )
                )
            for _, first_index, second_index in opposite_pairs:
                if first_index in used_arm_indices or second_index in used_arm_indices:
                    continue
                selected_pairs.append((first_index, second_index))
                used_arm_indices.update((first_index, second_index))

        for first_index, second_index in selected_pairs:
            first_point = contact_points[first_index]
            second_point = contact_points[second_index]
            virtual_edges.setdefault(first_point, []).append(second_point)
            virtual_edges.setdefault(second_point, []).append(first_point)

    return (
        crossing_mask,
        blocked_mask,
        {point: tuple(targets) for point, targets in virtual_edges.items()},
    )


def _true_crossing_mask(skeleton: np.ndarray) -> np.ndarray:
    """Locate junction clusters that contain two independent crossing lanes."""
    crossing_mask, _, _ = _crossing_lane_graph(skeleton)
    return crossing_mask


def _shortest_directional_routes(
    skeleton: np.ndarray,
    start: tuple[int, int],
    targets: set[tuple[int, int]],
    lane_graph: tuple[
        np.ndarray,
        dict[tuple[int, int], tuple[tuple[int, int], ...]],
    ] | None = None,
    pass_through_points: set[tuple[int, int]] | None = None,
) -> dict[tuple[int, int], tuple[list[tuple[int, int]], float]]:
    """Dijkstra over pixel + incoming-direction states.

    ``pass_through_points`` models a symbol drawn on top of a conductor.  A
    normal terminal is a hard stop: reaching it makes the route an object
    connection.  An inline load terminal is different; the conductor can
    continue through that point to a farther bus or transformer.  The caller
    still searches for the load itself in a separate pass, so this exception
    does not remove the load connection or make a load electrically connect
    to an arbitrary class.
    """
    if lane_graph is None:
        _, blocked_mask, virtual_edges = _crossing_lane_graph(skeleton)
    else:
        blocked_mask, virtual_edges = lane_graph
    start_state = (start[0], start[1], 0, 0)
    distances = {start_state: 0.0}
    parents: dict[tuple[int, int, int, int], tuple[int, int, int, int] | None] = {
        start_state: None
    }
    queue = [(0.0, start_state)]
    found: dict[tuple[int, int], tuple[list[tuple[int, int]], float]] = {}
    remaining = set(targets)
    pass_through_points = pass_through_points or set()

    while queue and remaining:
        cost, state = heapq.heappop(queue)
        if cost > distances.get(state, float("inf")) + 1e-9:
            continue
        x, y, in_dx, in_dy = state
        point = (x, y)
        if point in remaining and point not in pass_through_points:
            chain = []
            cursor: tuple[int, int, int, int] | None = state
            while cursor is not None:
                chain.append((cursor[0], cursor[1]))
                cursor = parents[cursor]
            chain.reverse()
            found[point] = (chain, cost)
            remaining.remove(point)
            # A component port is a physical terminal. Do not walk through it
            # to reach a more distant object on the same connected pixels.
            continue

        neighbours = [
            neighbour
            for neighbour in _neighbours(skeleton, point)
            if blocked_mask[neighbour[1], neighbour[0]] == 0
        ]
        neighbours.extend(virtual_edges.get(point, ()))
        degree = len(neighbours)
        for nx, ny in neighbours:
            dx, dy = nx - x, ny - y
            if in_dx and dx == -in_dx and dy == -in_dy:
                continue
            step = math.hypot(dx, dy)
            new_cost = cost + step + _turn_penalty(
                (in_dx, in_dy),
                (dx, dy),
                degree,
                junction_contact=point in virtual_edges,
            )
            next_state = (nx, ny, dx, dy)
            if new_cost + 1e-9 >= distances.get(next_state, float("inf")):
                continue
            distances[next_state] = new_cost
            parents[next_state] = state
            heapq.heappush(queue, (new_cost, next_state))
    return found


def _path_length(path: list[tuple[int, int]]) -> float:
    return sum(
        float(np.hypot(
            path[index][0] - path[index - 1][0],
            path[index][1] - path[index - 1][1],
        ))
        for index in range(1, len(path))
    )


def _path_straightness(path: list[tuple[int, int]]) -> float:
    """Measure how directly a raster path follows its end-to-end direction."""
    if len(path) < 2:
        return 0.0
    length = _path_length(path)
    if length <= 1e-6:
        return 0.0
    displacement = float(np.hypot(
        path[-1][0] - path[0][0],
        path[-1][1] - path[0][1],
    ))
    return float(np.clip(displacement / length, 0.0, 1.0))


def trace_electrical_connections(
    skeleton: np.ndarray,
    endpoint_to_component: dict[tuple[int, int], str],
    endpoint_to_port: dict[tuple[int, int], dict[str, Any]],
    component_classes: dict[str, str],
) -> list[dict[str, Any]]:
    """Enumerate and select conductor paths with electrical port capacities.

    Every detected object port is a hard graph terminal. In particular a
    load is a one-port device and can never be used as a waypoint to reach a
    farther bus. Independent conductors that merely overlap a load display
    box must be restored before this graph stage, without assigning that lane
    to the load port.
    """
    if skeleton is None or skeleton.ndim != 2 or not endpoint_to_component:
        return []

    ink = np.where(skeleton > 0, 255, 0).astype(np.uint8)
    _, blocked_crossings, virtual_crossing_edges = _crossing_lane_graph(ink)
    _, labels = cv2.connectedComponents(ink, connectivity=8)
    terminals_by_label: dict[int, list[tuple[int, int]]] = {}
    for endpoint in endpoint_to_component:
        x, y = endpoint
        if not (0 <= y < labels.shape[0] and 0 <= x < labels.shape[1]):
            continue
        label = int(labels[y, x])
        if label > 0:
            terminals_by_label.setdefault(label, []).append(endpoint)

    candidates_by_endpoints: dict[
        tuple[tuple[int, int], tuple[int, int]], dict[str, Any]
    ] = {}
    for terminals in terminals_by_label.values():
        if len(terminals) < 2:
            continue
        terminal_set = set(terminals)
        for start in terminals:
            start_component = endpoint_to_component[start]
            start_class = component_classes.get(start_component, "")
            possible_targets = {
                target for target in terminal_set
                if target != start
                and endpoint_to_component[target] != start_component
                and _pair_is_electrically_possible(
                    start_class,
                    component_classes.get(endpoint_to_component[target], ""),
                )
            }
            if not possible_targets:
                continue
            routes = _shortest_directional_routes(
                skeleton,
                start,
                possible_targets,
                lane_graph=(blocked_crossings, virtual_crossing_edges),
            )
            for target, (path, route_cost) in routes.items():
                target_component = endpoint_to_component[target]
                classes = {
                    component_classes.get(start_component, ""),
                    component_classes.get(target_component, ""),
                }
                length = _path_length(path)
                minimum_length = 3.0 if classes.intersection({"load", "generator"}) else 12.0
                if length < minimum_length:
                    continue
                source_port = endpoint_to_port.get(start, {})
                target_port = endpoint_to_port.get(target, {})
                port_score = min(
                    float(source_port.get("score", 0.0)),
                    float(target_port.get("score", 0.0)),
                )
                continuity = min(1.0, length / max(route_cost, 1e-6))
                straightness = _path_straightness(path)
                base_score = 0.68 * port_score + 0.32 * continuity
                jump_count = sum(
                    next_point in virtual_crossing_edges.get(point, ())
                    for point, next_point in zip(path, path[1:])
                )
                # Keep the normal one-endpoint capacity rule.  Only promote
                # a long, source-pixel-straight bus lane when the route did
                # not already rely on a virtual jump.  This lets a real
                # diagonal lane win over a branch switch at a crossing while
                # avoiding the global bus-reuse over-selection that previously
                # created several extra TEST17 lines.
                straight_lane_bonus = (
                    0.12
                    if (
                        classes == {"bus"}
                        and length >= 40.0
                        and straightness >= 0.78
                        and continuity <= 0.68
                        and jump_count == 0
                    )
                    else 0.0
                )
                selection_score = base_score + straight_lane_bonus
                endpoint_key = tuple(sorted((start, target)))
                candidate = {
                    "connected_to": [start_component, target_component],
                    "path": [(int(x), int(y)) for x, y in path],
                    "connection_score": float(selection_score),
                    "port_distances": {
                        start_component: float(source_port.get("distance", float("inf"))),
                        target_component: float(target_port.get("distance", float("inf"))),
                    },
                    "source_port": source_port.get("side"),
                    "target_port": target_port.get("side"),
                    "trace_method": "electrical_graph",
                    "source_endpoint": start,
                    "target_endpoint": target,
                    "route_cost": float(route_cost),
                    "pixel_length": float(length),
                    "continuity_score": float(continuity),
                    "straightness_score": float(straightness),
                    "jump_count": int(jump_count),
                }
                saved = candidates_by_endpoints.get(endpoint_key)
                if saved is None or candidate["connection_score"] > saved["connection_score"]:
                    candidates_by_endpoints[endpoint_key] = candidate

    selected = []
    used_endpoints: set[tuple[int, int]] = set()
    used_single_components: set[str] = set()
    ordered = sorted(
        candidates_by_endpoints.values(),
        key=lambda item: (
            item["connection_score"],
            item.get("straightness_score", 0.0),
            item["continuity_score"],
            -item["route_cost"] / max(item["pixel_length"], 1.0),
        ),
        reverse=True,
    )
    for candidate in ordered:
        first_endpoint = candidate["source_endpoint"]
        second_endpoint = candidate["target_endpoint"]
        if first_endpoint in used_endpoints or second_endpoint in used_endpoints:
            continue
        blocked = False
        for component_id, side in zip(
            candidate["connected_to"],
            (candidate.get("source_port"), candidate.get("target_port")),
        ):
            component_class = component_classes.get(component_id, "")
            if component_class in {"load", "generator"} and component_id in used_single_components:
                blocked = True
                break
        if blocked:
            continue

        selected.append(candidate)
        used_endpoints.update((first_endpoint, second_endpoint))
        for component_id, side in zip(
            candidate["connected_to"],
            (candidate.get("source_port"), candidate.get("target_port")),
        ):
            component_class = component_classes.get(component_id, "")
            if component_class in {"load", "generator"}:
                used_single_components.add(component_id)
    return selected

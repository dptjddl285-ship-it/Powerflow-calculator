"""
High-Precision AC Power Flow Solver (Newton-Raphson Method)
PowerLens Project - Core Power Flow Engine
"""

from __future__ import annotations

import math
import re
from typing import Any, Dict, List, Optional, Tuple
import numpy as np


class PowerFlowSolver:
    """
    Solves AC Power Flow equations using the Newton-Raphson method.
    Supports Slack, PV, and PQ buses, transformer off-nominal taps,
    and transmission line charging susceptance (pi-model).
    """

    def __init__(self, s_base: float = 100.0, tol: float = 1e-5, max_iter: int = 25):
        self.s_base = float(s_base)
        self.tol = float(tol)
        self.max_iter = int(max_iter)

    def _extract_bus_number(self, label: str, id_str: str) -> Optional[int]:
        """Extracts integer bus number, prioritizing label over id_str."""
        for text in [label, id_str]:
            if not text:
                continue
            cleaned = re.sub(r'^(?:bus|b)[_\s]*', '', text.strip(), flags=re.I)
            match = re.search(r'\b(\d+)\b', cleaned)
            if match:
                return int(match.group(1))
            digits = re.sub(r'[^\d]', '', text)
            if digits:
                return int(digits)
        return None

    def parse_elements(self, elements: List[Dict[str, Any]]) -> Dict[str, Any]:
        """
        Parses canvas DrawingElement JSON list into structured buses, gens, loads, and branches.
        """
        buses: Dict[int, Dict[str, Any]] = {}
        gens_by_bus: Dict[int, List[Dict[str, Any]]] = {}
        loads_by_bus: Dict[int, List[Dict[str, Any]]] = {}
        branches: List[Dict[str, Any]] = []

        # 1. First pass: Collect all Bus elements
        for el in elements:
            el_type = str(el.get("type", "")).lower()
            if el_type == "bus" or el_type == "tool.bus":
                el_id = str(el.get("id", ""))
                label = str(el.get("label", ""))
                b_num = self._extract_bus_number(label, el_id)
                if b_num is None:
                    continue

                is_slack = bool(el.get("isSlack") or el.get("is_slack") or False)
                v_pu = float(el.get("vPu") or el.get("v_pu") or 1.0)
                theta_deg = float(el.get("thetaDeg") or el.get("theta_deg") or 0.0)

                buses[b_num] = {
                    "bus_num": b_num,
                    "element_id": el_id,
                    "label": label or f"Bus {b_num}",
                    "is_slack": is_slack,
                    "v_spec": v_pu,
                    "theta_spec_rad": math.radians(theta_deg),
                    "pos_x": float(el.get("position", {}).get("dx", 0.0) if isinstance(el.get("position"), dict) else 0.0),
                    "pos_y": float(el.get("position", {}).get("dy", 0.0) if isinstance(el.get("position"), dict) else 0.0),
                }

        # Element ID to Bus Number lookup with comprehensive synonyms
        el_id_to_bus: Dict[str, int] = {}
        for b_num, b in buses.items():
            el_id_to_bus[b["element_id"]] = b_num
            el_id_to_bus[b["label"]] = b_num
            el_id_to_bus[str(b_num)] = b_num
            el_id_to_bus[f"bus_{b_num}"] = b_num
            el_id_to_bus[f"node_{b_num}"] = b_num
            el_id_to_bus[f"b_{b_num}"] = b_num
            el_id_to_bus[f"Bus {b_num}"] = b_num

        # 2. Second pass: Collect Generators & Loads
        for el in elements:
            el_type = str(el.get("type", "")).lower()
            el_id = str(el.get("id", ""))
            label = str(el.get("label", ""))
            parent_bus_id = el.get("parentBusId") or el.get("parent_bus_id")

            target_bus_num: Optional[int] = None
            if parent_bus_id and str(parent_bus_id) in el_id_to_bus:
                target_bus_num = el_id_to_bus[str(parent_bus_id)]
            if target_bus_num is None and parent_bus_id:
                target_bus_num = self._extract_bus_number("", str(parent_bus_id))
            if target_bus_num is None:
                target_bus_num = self._extract_bus_number(label, el_id)

            if "gen" in el_type:
                p_val = float(el.get("pPu") or el.get("p_pu") or 0.0)
                q_val = float(el.get("qPu") or el.get("q_pu") or 0.0)
                v_set = float(el.get("vPu") or el.get("v_pu") or 1.0)
                is_slack = bool(el.get("isSlack") or el.get("is_slack") or False)

                p_pu = p_val / self.s_base if p_val > 10.0 else p_val
                q_pu = q_val / self.s_base if q_val > 10.0 else q_val

                if target_bus_num is not None:
                    if target_bus_num not in buses:
                        buses[target_bus_num] = {
                            "bus_num": target_bus_num,
                            "element_id": f"bus_{target_bus_num}",
                            "label": f"Bus {target_bus_num}",
                            "is_slack": is_slack,
                            "v_spec": v_set,
                            "theta_spec_rad": 0.0,
                        }
                    if is_slack:
                        buses[target_bus_num]["is_slack"] = True

                    gens_by_bus.setdefault(target_bus_num, []).append({
                        "p_pu": p_pu,
                        "q_pu": q_pu,
                        "v_set": v_set,
                        "is_slack": is_slack,
                    })

            elif "load" in el_type:
                p_val = float(el.get("pPu") or el.get("p_pu") or 0.0)
                q_val = float(el.get("qPu") or el.get("q_pu") or 0.0)

                p_pu = p_val / self.s_base if p_val > 10.0 else p_val
                q_pu = q_val / self.s_base if q_val > 10.0 else q_val

                if target_bus_num is not None:
                    if target_bus_num not in buses:
                        buses[target_bus_num] = {
                            "bus_num": target_bus_num,
                            "element_id": f"bus_{target_bus_num}",
                            "label": f"Bus {target_bus_num}",
                            "is_slack": False,
                            "v_spec": 1.0,
                            "theta_spec_rad": 0.0,
                        }
                    loads_by_bus.setdefault(target_bus_num, []).append({
                        "p_pu": p_pu,
                        "q_pu": q_pu,
                    })

        # Also check if any bus element itself has load (pPu / qPu) and no separate load element was added
        for el in elements:
            el_type = str(el.get("type", "")).lower()
            if "bus" in el_type and not ("gen" in el_type or "load" in el_type):
                b_num = self._extract_bus_number(str(el.get("label", "")), str(el.get("id", "")))
                if b_num is not None and b_num not in loads_by_bus:
                    p_val = float(el.get("pPu") or el.get("p_pu") or 0.0)
                    q_val = float(el.get("qPu") or el.get("q_pu") or 0.0)
                    p_pu = p_val / self.s_base if p_val > 10.0 else p_val
                    q_pu = q_val / self.s_base if q_val > 10.0 else q_val
                    if abs(p_pu) > 1e-6 or abs(q_pu) > 1e-6:
                        loads_by_bus.setdefault(b_num, []).append({
                            "p_pu": p_pu,
                            "q_pu": q_pu,
                        })

        # 3. Third pass: Collect Branches (Lines and Transformers)
        for el in elements:
            el_type = str(el.get("type", "")).lower()
            if "line" in el_type or "trans" in el_type:
                start_id = str(el.get("startElementId") or el.get("start_element_id") or "")
                end_id = str(el.get("endElementId") or el.get("end_element_id") or "")
                label = str(el.get("label", ""))

                fb = None
                tb = None

                # 1. Try resolving from label format (e.g. "Line 1-2", "1_2", "1-2")
                if label:
                    match = re.search(r'(\d+)\s*[-~↔_]\s*(\d+)', label)
                    if match:
                        cand_f = int(match.group(1))
                        cand_t = int(match.group(2))
                        if cand_f in buses and cand_t in buses:
                            fb, tb = cand_f, cand_t

                # 2. Try resolving from connected element IDs
                if fb is None or tb is None:
                    if start_id in el_id_to_bus:
                        fb = el_id_to_bus[start_id]
                    if end_id in el_id_to_bus:
                        tb = el_id_to_bus[end_id]

                # 3. Fallback: Parse digits directly from start/end IDs
                if fb is None or tb is None:
                    if start_id and end_id:
                        cand_f = self._extract_bus_number("", start_id)
                        cand_t = self._extract_bus_number("", end_id)
                        if cand_f in buses and cand_t in buses:
                            fb, tb = cand_f, cand_t

                # 4. Fallback: Parse digits from element ID (e.g. "T_3_24")
                if fb is None or tb is None:
                    el_id = str(el.get("id", ""))
                    match = re.search(r'(\d+)\s*[-~↔_]\s*(\d+)', el_id)
                    if match:
                        cand_f = int(match.group(1))
                        cand_t = int(match.group(2))
                        if cand_f in buses and cand_t in buses:
                            fb, tb = cand_f, cand_t

                # 5. Fallback for transformers connected via lines
                if (fb is None or tb is None) and "trans" in el_type:
                    el_id = str(el.get("id", ""))
                    connected_buses = []
                    for other in elements:
                        if "line" in str(other.get("type", "")).lower():
                            s_id = str(other.get("startElementId") or other.get("start_element_id") or "")
                            e_id = str(other.get("endElementId") or other.get("end_element_id") or "")
                            if s_id == el_id and e_id:
                                b_cand = el_id_to_bus.get(e_id) or self._extract_bus_number("", e_id)
                                if b_cand in buses and b_cand not in connected_buses:
                                    connected_buses.append(b_cand)
                            elif e_id == el_id and s_id:
                                b_cand = el_id_to_bus.get(s_id) or self._extract_bus_number("", s_id)
                                if b_cand in buses and b_cand not in connected_buses:
                                    connected_buses.append(b_cand)
                    if len(connected_buses) >= 2:
                        fb = fb or connected_buses[0]
                        tb = tb or connected_buses[1]
                    elif len(connected_buses) == 1 and fb is None:
                        fb = connected_buses[0]

                if fb is None or tb is None or fb == tb:
                    continue

                r_pu = float(el.get("rPu") or el.get("r_pu") or 0.01)
                x_pu = float(el.get("xPu") or el.get("x_pu") or 0.05)
                b_pu = float(el.get("bPu") or el.get("b_pu") or 0.0)
                tap = float(el.get("tapRatio") or el.get("tap_ratio") or 1.0)
                if "trans" in el_type and tap <= 0:
                    tap = 1.0

                if abs(x_pu) < 1e-5:
                    x_pu = 0.05

                branches.append({
                    "from_bus": fb,
                    "to_bus": tb,
                    "r_pu": r_pu,
                    "x_pu": x_pu,
                    "b_pu": b_pu,
                    "tap": tap,
                    "label": label or f"Line {fb}-{tb}",
                })

        return {
            "buses": buses,
            "gens_by_bus": gens_by_bus,
            "loads_by_bus": loads_by_bus,
            "branches": branches,
        }

    def solve(self, elements: List[Dict[str, Any]]) -> Dict[str, Any]:
        """
        Main entry point: Solves power flow for elements and returns formatted results.
        """
        parsed = self.parse_elements(elements)
        buses_dict = parsed["buses"]
        gens_by_bus = parsed["gens_by_bus"]
        loads_by_bus = parsed["loads_by_bus"]
        branches = parsed["branches"]

        if not buses_dict:
            return {
                "status": "error",
                "converged": False,
                "message": "도면에서 모선(Bus)을 찾을 수 없습니다. 모선을 추가하거나 검수실에서 변환해 주세요.",
            }

        # Sorted list of bus numbers
        bus_numbers = sorted(buses_dict.keys())
        N = len(bus_numbers)
        bus_idx = {b_num: i for i, b_num in enumerate(bus_numbers)}

        # Classify buses: Slack, PV, PQ
        slack_bus_num = None
        for b_num in bus_numbers:
            if buses_dict[b_num].get("is_slack"):
                slack_bus_num = b_num
                break

        if slack_bus_num is None:
            for b_num in bus_numbers:
                if b_num in gens_by_bus:
                    slack_bus_num = b_num
                    break
            if slack_bus_num is None:
                slack_bus_num = bus_numbers[0]
            buses_dict[slack_bus_num]["is_slack"] = True

        bus_types: List[str] = []
        v = np.ones(N, dtype=float)
        theta = np.zeros(N, dtype=float)
        p_spec = np.zeros(N, dtype=float)
        q_spec = np.zeros(N, dtype=float)

        p_gen_init = np.zeros(N, dtype=float)
        q_gen_init = np.zeros(N, dtype=float)
        p_load_init = np.zeros(N, dtype=float)
        q_load_init = np.zeros(N, dtype=float)

        for i, b_num in enumerate(bus_numbers):
            b_info = buses_dict[b_num]
            g_list = gens_by_bus.get(b_num, [])
            p_g = sum(g["p_pu"] for g in g_list)
            q_g = sum(g["q_pu"] for g in g_list)
            p_gen_init[i] = p_g
            q_gen_init[i] = q_g

            l_list = loads_by_bus.get(b_num, [])
            p_l = sum(l["p_pu"] for l in l_list)
            q_l = sum(l["q_pu"] for l in l_list)
            p_load_init[i] = p_l
            q_load_init[i] = q_l

            p_spec[i] = p_g - p_l
            q_spec[i] = q_g - q_l

            if b_num == slack_bus_num:
                bus_types.append("SLACK")
                v[i] = b_info.get("v_spec", 1.0)
                theta[i] = 0.0  # Slack reference bus is strictly 0.0 rad
            elif len(g_list) > 0:
                bus_types.append("PV")
                v_set = g_list[0].get("v_set", 1.0)
                v[i] = v_set
                theta[i] = 0.0
            else:
                bus_types.append("PQ")
                v[i] = 1.0
                theta[i] = 0.0

        # Construct Y-bus matrix
        Y_bus = np.zeros((N, N), dtype=complex)
        for br in branches:
            fb, tb = br["from_bus"], br["to_bus"]
            if fb not in bus_idx or tb not in bus_idx:
                continue
            i, j = bus_idx[fb], bus_idx[tb]
            r = br["r_pu"]
            x = br["x_pu"]
            b_sh = br["b_pu"]
            tap = br.get("tap", 1.0)

            z = complex(r, x)
            y = 1.0 / z
            y_sh = complex(0.0, b_sh / 2.0)

            Y_bus[i, i] += (y + y_sh) / (tap * tap)
            Y_bus[j, j] += (y + y_sh)
            Y_bus[i, j] -= y / tap
            Y_bus[j, i] -= y / tap

        G = Y_bus.real
        B = Y_bus.imag

        pv_pq_idx = [i for i, t in enumerate(bus_types) if t in ("PV", "PQ")]
        pq_idx = [i for i, t in enumerate(bus_types) if t == "PQ"]

        n_p = len(pv_pq_idx)
        n_q = len(pq_idx)

        converged = False
        iteration = 0
        max_mismatch = 0.0

        # Newton-Raphson Iteration Loop
        for it in range(self.max_iter):
            iteration = it + 1

            P_calc = np.zeros(N, dtype=float)
            Q_calc = np.zeros(N, dtype=float)

            for i in range(N):
                theta_diff = theta[i] - theta
                P_calc[i] = v[i] * np.sum(v * (G[i, :] * np.cos(theta_diff) + B[i, :] * np.sin(theta_diff)))
                Q_calc[i] = v[i] * np.sum(v * (G[i, :] * np.sin(theta_diff) - B[i, :] * np.cos(theta_diff)))

            dP = p_spec[pv_pq_idx] - P_calc[pv_pq_idx]
            dQ = q_spec[pq_idx] - Q_calc[pq_idx]

            mismatches = np.concatenate([dP, dQ]) if n_q > 0 else dP
            max_mismatch = float(np.max(np.abs(mismatches))) if len(mismatches) > 0 else 0.0

            if max_mismatch < self.tol:
                converged = True
                break

            # Jacobian
            J11 = np.zeros((n_p, n_p), dtype=float)
            for r, i in enumerate(pv_pq_idx):
                for c, j in enumerate(pv_pq_idx):
                    if i == j:
                        J11[r, c] = -Q_calc[i] - (v[i] ** 2) * B[i, i]
                    else:
                        th_ij = theta[i] - theta[j]
                        J11[r, c] = v[i] * v[j] * (G[i, j] * math.sin(th_ij) - B[i, j] * math.cos(th_ij))

            J12 = np.zeros((n_p, n_q), dtype=float)
            for r, i in enumerate(pv_pq_idx):
                for c, j in enumerate(pq_idx):
                    if i == j:
                        J12[r, c] = P_calc[i] + (v[i] ** 2) * G[i, i]
                    else:
                        th_ij = theta[i] - theta[j]
                        J12[r, c] = v[i] * v[j] * (G[i, j] * math.cos(th_ij) + B[i, j] * math.sin(th_ij))

            J21 = np.zeros((n_q, n_p), dtype=float)
            for r, i in enumerate(pq_idx):
                for c, j in enumerate(pv_pq_idx):
                    if i == j:
                        J21[r, c] = P_calc[i] - (v[i] ** 2) * G[i, i]
                    else:
                        th_ij = theta[i] - theta[j]
                        J21[r, c] = -v[i] * v[j] * (G[i, j] * math.cos(th_ij) + B[i, j] * math.sin(th_ij))

            J22 = np.zeros((n_q, n_q), dtype=float)
            for r, i in enumerate(pq_idx):
                for c, j in enumerate(pq_idx):
                    if i == j:
                        J22[r, c] = Q_calc[i] - (v[i] ** 2) * B[i, i]
                    else:
                        th_ij = theta[i] - theta[j]
                        J22[r, c] = v[i] * v[j] * (G[i, j] * math.sin(th_ij) - B[i, j] * math.cos(th_ij))

            if n_q > 0:
                J = np.block([[J11, J12], [J21, J22]])
            else:
                J = J11

            try:
                dx = np.linalg.solve(J, mismatches)
            except np.linalg.LinAlgError:
                dx, _, _, _ = np.linalg.lstsq(J, mismatches, rcond=None)

            # Robust damping step to prevent overshooting or divergence
            d_theta = np.clip(dx[:n_p], -0.6, 0.6)
            theta[pv_pq_idx] += d_theta

            # Wrap angles to [-pi, pi] to prevent runaway angle accumulation
            theta[pv_pq_idx] = np.mod(theta[pv_pq_idx] + np.pi, 2 * np.pi) - np.pi

            if n_q > 0:
                d_v_ratio = np.clip(dx[n_p:], -0.25, 0.25)
                v[pq_idx] += v[pq_idx] * d_v_ratio
                # Clamp PQ voltages to physical operating limits [0.5, 1.5]
                v[pq_idx] = np.clip(v[pq_idx], 0.5, 1.5)

        # Final Power Calculations at convergence
        P_final = np.zeros(N, dtype=float)
        Q_final = np.zeros(N, dtype=float)
        for i in range(N):
            theta_diff = theta[i] - theta
            P_final[i] = v[i] * np.sum(v * (G[i, :] * np.cos(theta_diff) + B[i, :] * np.sin(theta_diff)))
            Q_final[i] = v[i] * np.sum(v * (G[i, :] * np.sin(theta_diff) - B[i, :] * np.cos(theta_diff)))

        p_gen_res = np.copy(p_gen_init)
        q_gen_res = np.copy(q_gen_init)

        for i, b_num in enumerate(bus_numbers):
            if bus_types[i] == "SLACK":
                p_gen_res[i] = P_final[i] + p_load_init[i]
                q_gen_res[i] = Q_final[i] + q_load_init[i]
            elif bus_types[i] == "PV":
                q_gen_res[i] = Q_final[i] + q_load_init[i]

        # Calculate Branch Power Flows & Losses
        line_results = []
        total_p_loss_pu = 0.0
        total_q_loss_pu = 0.0

        for br in branches:
            fb, tb = br["from_bus"], br["to_bus"]
            if fb not in bus_idx or tb not in bus_idx:
                continue
            i, j = bus_idx[fb], bus_idx[tb]
            r, x, b_sh, tap = br["r_pu"], br["x_pu"], br["b_pu"], br.get("tap", 1.0)
            y = 1.0 / complex(r, x)
            y_sh = complex(0.0, b_sh / 2.0)

            V_i = v[i] * complex(math.cos(theta[i]), math.sin(theta[i]))
            V_j = v[j] * complex(math.cos(theta[j]), math.sin(theta[j]))

            I_ij = (y / (tap * tap) + y_sh / (tap * tap)) * V_i - (y / tap) * V_j
            S_ij = V_i * np.conj(I_ij)
            P_ij, Q_ij = S_ij.real, S_ij.imag

            I_ji = (y + y_sh) * V_j - (y / tap) * V_i
            S_ji = V_j * np.conj(I_ji)
            P_ji, Q_ji = S_ji.real, S_ji.imag

            loss_p = P_ij + P_ji
            loss_q = Q_ij + Q_ji
            total_p_loss_pu += max(0.0, loss_p)
            total_q_loss_pu += loss_q

            line_results.append({
                "from_bus": fb,
                "to_bus": tb,
                "p_from_mw": round(P_ij * self.s_base, 4),
                "q_from_mvar": round(Q_ij * self.s_base, 4),
                "p_to_mw": round(P_ji * self.s_base, 4),
                "q_to_mvar": round(Q_ji * self.s_base, 4),
                "loss_p_mw": round(loss_p * self.s_base, 4),
                "loss_q_mvar": round(loss_q * self.s_base, 4),
                "p_from_pu": round(P_ij, 5),
                "q_from_pu": round(Q_ij, 5),
                "loss_p_pu": round(loss_p, 5),
                "loss_q_pu": round(loss_q, 5),
                "label": br.get("label", f"Line {fb}-{tb}"),
            })

        # Format Bus Results matching exact user requirement:
        # Bus,Volt,Angle,Pgen,Qgen,Pload,Qload
        bus_results = []
        csv_rows = ["Bus,Volt,Angle,Pgen,Qgen,Pload,Qload"]

        for i, b_num in enumerate(bus_numbers):
            v_val = round(float(v[i]), 4)
            ang_val = round(float(math.degrees(theta[i])), 4)
            p_g_mw = round(float(p_gen_res[i] * self.s_base), 4)
            q_g_mvar = round(float(q_gen_res[i] * self.s_base), 4)
            p_l_mw = round(float(p_load_init[i] * self.s_base), 4)
            q_l_mvar = round(float(q_load_init[i] * self.s_base), 4)

            p_g_pu = round(float(p_gen_res[i]), 5)
            q_g_pu = round(float(q_gen_res[i]), 5)
            p_l_pu = round(float(p_load_init[i]), 5)
            q_l_pu = round(float(q_load_init[i]), 5)

            bus_row = {
                "bus": b_num,
                "volt": v_val,
                "angle": ang_val,
                "pgen": p_g_mw,
                "qgen": q_g_mvar,
                "pload": p_l_mw,
                "qload": q_l_mvar,
                # Additional fields for PU toggle and element update
                "volt_pu": v_val,
                "angle_deg": ang_val,
                "pgen_pu": p_g_pu,
                "qgen_pu": q_g_pu,
                "pload_pu": p_l_pu,
                "qload_pu": q_l_pu,
                "type": bus_types[i],
            }
            bus_results.append(bus_row)
            csv_rows.append(f"{b_num},{v_val:.4f},{ang_val:.4f},{p_g_mw:.4f},{q_g_mvar:.4f},{p_l_mw:.4f},{q_l_mvar:.4f}")

        total_gen_p_mw = float(np.sum(p_gen_res) * self.s_base)
        total_gen_q_mvar = float(np.sum(q_gen_res) * self.s_base)
        total_load_p_mw = float(np.sum(p_load_init) * self.s_base)
        total_load_q_mvar = float(np.sum(q_load_init) * self.s_base)
        total_loss_p_mw = float(total_p_loss_pu * self.s_base)
        total_loss_q_mvar = float(total_q_loss_pu * self.s_base)

        return {
            "status": "success",
            "converged": bool(converged),
            "iterations": iteration,
            "max_mismatch": round(max_mismatch, 8),
            "slack_bus": slack_bus_num,
            "total_buses": N,
            "total_branches": len(branches),
            "summary": {
                "total_gen_p_mw": round(total_gen_p_mw, 3),
                "total_gen_q_mvar": round(total_gen_q_mvar, 3),
                "total_load_p_mw": round(total_load_p_mw, 3),
                "total_load_q_mvar": round(total_load_q_mvar, 3),
                "total_loss_p_mw": round(total_loss_p_mw, 3),
                "total_loss_q_mvar": round(total_loss_q_mvar, 3),
            },
            "bus_results": bus_results,
            "line_results": line_results,
            "csv_text": "\n".join(csv_rows),
        }

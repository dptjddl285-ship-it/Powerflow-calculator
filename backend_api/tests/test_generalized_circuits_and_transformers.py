"""
Comprehensive Tests for General Parallel Lines (복회선),
Transformer 2-Port Topology, Parameter & Tap Ratio Preservation,
and Pure IEEE-24 Hardcoding Purge.
"""

from __future__ import annotations
import os
import sys
import unittest
import numpy as np
import pandas as pd
import io

backend_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

from core.power_flow_solver import PowerFlowSolver
from core.excel_case_importer import ExcelCaseImporter


class TestGeneralizedCircuitsAndTransformers(unittest.TestCase):
    def setUp(self):
        self.importer = ExcelCaseImporter()
        self.solver = PowerFlowSolver(s_base=100.0, tol=1e-5, max_iter=30)

    def _create_in_memory_excel(self, branch_rows, transformer_rows=None, bus_rows=None, gen_rows=None):
        """Helper to create an in-memory Excel workbook for testing without filesystem files."""
        output = io.BytesIO()
        with pd.ExcelWriter(output, engine='openpyxl') as writer:
            # Bus sheet
            if bus_rows is None:
                bus_rows = [
                    {'Bus': 1, 'Type': 3, 'Pload (MW)': 0.0, 'Qload (MVAR)': 0.0, 'Vm (pu)': 1.0, 'Va (degree)': 0.0},
                    {'Bus': 2, 'Type': 1, 'Pload (MW)': 40.0, 'Qload (MVAR)': 20.0, 'Vm (pu)': 1.0, 'Va (degree)': 0.0},
                ]
            pd.DataFrame(bus_rows).to_excel(writer, sheet_name='bus', index=False)

            # Generator sheet
            if gen_rows is None:
                gen_rows = [
                    {'Id': 1, 'Bus': 1, 'PG (MW)': 0.0, 'QG (MVAR)': 0.0, 'Voltage setpoint (pu)': 1.0, 'is_slack': True},
                ]
            pd.DataFrame(gen_rows).to_excel(writer, sheet_name='generator', index=False)

            # Branch sheet
            pd.DataFrame(branch_rows).to_excel(writer, sheet_name='branch', index=False)

            # Transformer sheet
            if transformer_rows is not None:
                pd.DataFrame(transformer_rows).to_excel(writer, sheet_name='transformer', index=False)

            # Param sheet
            pd.DataFrame([{'sbase (MVA)': 100.0}]).to_excel(writer, sheet_name='param', index=False)

        output.seek(0)
        return output.getvalue()

    def test_1_single_circuit(self):
        """
        TEST 1 - 단일 회선
        Excel: A-B R=R, X=X, B=B
        예상: R_eq=R, X_eq=X, B_eq=B
        """
        R, X, B = 0.012, 0.048, 0.035
        excel_bytes = self._create_in_memory_excel([
            {'From': 1, 'To': 2, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B}
        ])
        parsed = self.importer.parse_excel(excel_bytes)
        br = parsed['branches']['1_2']

        self.assertAlmostEqual(br['r_pu'], R, places=6)
        self.assertAlmostEqual(br['x_pu'], X, places=6)
        self.assertAlmostEqual(br['b_pu'], B, places=6)
        self.assertEqual(br['circuit_count'], 1)

    def test_2_double_circuit_parallel_equivalent(self):
        """
        TEST 2 - 동일한 복회선 2개
        Excel:
        A-B R=R, X=X, B=B
        A-B R=R, X=X, B=B
        도면에는 A-B 선이 하나만 존재해도 된다.
        예상:
        R_eq = R/2, X_eq = X/2, B_eq = 2B
        Ybus 또는 계산 결과가 동일한 두 병렬 branch를 직접 넣은 경우와 동일해야 한다.
        """
        R, X, B = 0.016, 0.064, 0.040
        # Use arbitrary non-IEEE24 bus numbers to prove no hardcoding
        fb, tb = 5, 12
        excel_bytes = self._create_in_memory_excel(
            branch_rows=[
                {'From': fb, 'To': tb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B},
                {'From': fb, 'To': tb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B},
            ],
            bus_rows=[
                {'Bus': fb, 'Type': 3, 'Pload (MW)': 0.0, 'Qload (MVAR)': 0.0, 'Vm (pu)': 1.0, 'Va (degree)': 0.0},
                {'Bus': tb, 'Type': 1, 'Pload (MW)': 20.0, 'Qload (MVAR)': 10.0, 'Vm (pu)': 1.0, 'Va (degree)': 0.0},
            ],
            gen_rows=[
                {'Id': 1, 'Bus': fb, 'PG (MW)': 0.0, 'QG (MVAR)': 0.0, 'Voltage setpoint (pu)': 1.0, 'is_slack': True},
            ]
        )
        parsed = self.importer.parse_excel(excel_bytes)
        br = parsed['branches'][f"{fb}_{tb}"]

        self.assertAlmostEqual(br['r_pu'], R / 2.0, places=6)
        self.assertAlmostEqual(br['x_pu'], X / 2.0, places=6)
        self.assertAlmostEqual(br['b_pu'], B * 2.0, places=6)
        self.assertEqual(br['circuit_count'], 2)

        # Build elements with single equivalent line
        elements_single_eq = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.2, 'qPu': 0.1},
            {'id': f'line_{fb}_{tb}', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}'},
        ]
        applied_elements, _ = self.importer.apply_to_elements(elements_single_eq, parsed)
        res_eq = self.solver.solve(applied_elements)

        # Build elements with 2 separate parallel lines directly
        elements_two_lines = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.2, 'qPu': 0.1},
            {'id': f'line1_{fb}_{tb}', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}', 'rPu': R, 'xPu': X, 'bPu': B},
            {'id': f'line2_{fb}_{tb}', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}', 'rPu': R, 'xPu': X, 'bPu': B},
        ]
        res_two = self.solver.solve(elements_two_lines)

        self.assertTrue(res_eq['converged'])
        self.assertTrue(res_two['converged'])
        # Compare bus voltages between equivalent single line and 2 direct parallel lines
        v_eq = {r['bus']: r['volt_pu'] for r in res_eq['bus_results']}
        v_two = {r['bus']: r['volt_pu'] for r in res_two['bus_results']}
        self.assertAlmostEqual(v_eq[tb], v_two[tb], places=5)

    def test_3_triple_circuit_arbitrary_buses(self):
        """
        TEST 3 - 3회선
        Excel에 동일한 A-B branch가 3행이면
        R_eq = R/3, X_eq = X/3, B_eq = 3B
        특정 bus 번호에 의존하지 않아야 한다.
        """
        R, X, B = 0.030, 0.090, 0.060
        fb, tb = 17, 29  # Arbitrary bus numbers outside any standard 24-bus range
        excel_bytes = self._create_in_memory_excel(
            branch_rows=[
                {'From': fb, 'To': tb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B},
                {'From': tb, 'To': fb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B},  # reversed From-To
                {'From': fb, 'To': tb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B},
            ],
            bus_rows=[
                {'Bus': fb, 'Type': 3, 'Pload (MW)': 0.0, 'Qload (MVAR)': 0.0, 'Vm (pu)': 1.0, 'Va (degree)': 0.0},
                {'Bus': tb, 'Type': 1, 'Pload (MW)': 30.0, 'Qload (MVAR)': 15.0, 'Vm (pu)': 1.0, 'Va (degree)': 0.0},
            ]
        )
        parsed = self.importer.parse_excel(excel_bytes)
        br = parsed['branches'][f"{fb}_{tb}"]

        self.assertAlmostEqual(br['r_pu'], R / 3.0, places=6)
        self.assertAlmostEqual(br['x_pu'], X / 3.0, places=6)
        self.assertAlmostEqual(br['b_pu'], B * 3.0, places=6)
        self.assertEqual(br['circuit_count'], 3)

    def test_4_transformer_topology_intermediate_2_port(self):
        """
        TEST 4 - Transformer topology
        도면 topology:
        Bus A --- line --- Transformer --- line --- Bus B
        결과:
        Transformer A-B 하나이어야 한다.
        중간의 짧은 선 2개를 별도 transmission branch로 만들면 안 된다.
        """
        fb, tb = 4, 8
        elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.1, 'qPu': 0.05},
            {'id': 'tr_sym_1', 'type': 'transformer', 'label': f'T {fb}-{tb}', 'rPu': 0.005, 'xPu': 0.04, 'tapRatio': 1.02},
            # Two short lead lines connecting buses to the transformer symbol
            {'id': 'lead_1', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': 'tr_sym_1'},
            {'id': 'lead_2', 'type': 'line', 'startElementId': 'tr_sym_1', 'endElementId': f'bus_{tb}'},
        ]

        parsed = self.solver.parse_elements(elements)
        branches = parsed['branches']

        # Must have exactly ONE branch (the transformer)
        self.assertEqual(len(branches), 1, f"Expected exactly 1 branch, but got {len(branches)}: {branches}")
        tr_br = branches[0]
        self.assertEqual({tr_br['from_bus'], tr_br['to_bus']}, {fb, tb})
        self.assertTrue(tr_br.get('is_transformer', False))
        self.assertAlmostEqual(tr_br['r_pu'], 0.005)
        self.assertAlmostEqual(tr_br['x_pu'], 0.04)
        self.assertAlmostEqual(tr_br['tap'], 1.02)

    def test_5_transformer_parameter_preservation(self):
        """
        TEST 5 - Transformer parameter preservation
        Excel의 Transformer A-B에
        R != 0, X != 0, tap != 1.0을 넣는다.
        topology recognition 이후 simulation 직전까지 동일한 R/X/tap이 유지되는지 검증.
        """
        fb, tb = 8, 19
        R, X, tap = 0.0035, 0.075, 1.045
        excel_bytes = self._create_in_memory_excel(
            branch_rows=[
                {'From': fb, 'To': tb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': 0.0}
            ],
            transformer_rows=[
                {'From': fb, 'To': tb, 'Tap': tap}
            ],
            bus_rows=[
                {'Bus': fb, 'Type': 3, 'Pload (MW)': 0.0, 'Qload (MVAR)': 0.0, 'Vm (pu)': 1.0, 'Va (degree)': 0.0},
                {'Bus': tb, 'Type': 1, 'Pload (MW)': 15.0, 'Qload (MVAR)': 5.0, 'Vm (pu)': 1.0, 'Va (degree)': 0.0},
            ]
        )
        data = self.importer.parse_excel(excel_bytes)
        self.assertAlmostEqual(data['transformers'][f"{fb}_{tb}"]['tap'], tap)
        self.assertAlmostEqual(data['transformers'][f"{fb}_{tb}"]['r_pu'], R)
        self.assertAlmostEqual(data['transformers'][f"{fb}_{tb}"]['x_pu'], X)

        elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb},
            {'id': 'tr_1', 'type': 'transformer'},
            {'id': 'lead_a', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': 'tr_1'},
            {'id': 'lead_b', 'type': 'line', 'startElementId': 'tr_1', 'endElementId': f'bus_{tb}'},
        ]
        applied, _ = self.importer.apply_to_elements(elements, data)

        tr_el = next(e for e in applied if e['id'] == 'tr_1')
        self.assertAlmostEqual(tr_el['rPu'], R)
        self.assertAlmostEqual(tr_el['xPu'], X)
        self.assertAlmostEqual(tr_el['tapRatio'], tap)
        self.assertEqual(tr_el['tapFromBus'], fb)
        self.assertEqual(tr_el['tapToBus'], tb)

        parsed_solver = self.solver.parse_elements(applied)
        self.assertEqual(len(parsed_solver['branches']), 1)
        br = parsed_solver['branches'][0]
        self.assertEqual(br['from_bus'], fb)
        self.assertEqual(br['to_bus'], tb)
        self.assertAlmostEqual(br['r_pu'], R)
        self.assertAlmostEqual(br['x_pu'], X)
        self.assertAlmostEqual(br['tap'], tap)

    def test_6_transformer_tap_actual_solver_impact(self):
        """
        TEST 6 - Transformer tap 실제 적용
        tap=1.0인 경우와 tap!=1.0인 경우의 Ybus 또는 power-flow 결과가 달라져야 한다.
        PowerFlowSolver가 실제 Ybus 계산에서 그 값을 사용하는지 검증.
        """
        fb, tb = 1, 2
        R, X = 0.01, 0.05

        def run_case_with_tap(tap_ratio):
            elements = [
                {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
                {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.5, 'qPu': 0.2},
                {
                    'id': 'tr_1', 'type': 'transformer',
                    'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}',
                    'rPu': R, 'xPu': X, 'bPu': 0.0, 'tapRatio': tap_ratio,
                    'tapFromBus': fb, 'tapToBus': tb,
                },
            ]
            return self.solver.solve(elements)

        res_nominal = run_case_with_tap(1.0)
        res_tapped = run_case_with_tap(1.05)

        self.assertTrue(res_nominal['converged'])
        self.assertTrue(res_tapped['converged'])

        v_nom = next(r['volt_pu'] for r in res_nominal['bus_results'] if r['bus'] == tb)
        v_tap = next(r['volt_pu'] for r in res_tapped['bus_results'] if r['bus'] == tb)

        # Voltage at bus 2 MUST be measurably different when tap is adjusted from 1.0 to 1.05
        self.assertNotAlmostEqual(v_nom, v_tap, places=3,
                                 msg=f"Tap ratio 1.05 did not alter voltage! v_nom={v_nom}, v_tap={v_tap}")
        print(f"\n[TEST 6 Result] Nominal voltage: {v_nom:.5f} pu, Tapped (1.05) voltage: {v_tap:.5f} pu -> delta={abs(v_tap - v_nom):.5f} pu")

    def test_7_regression_tests(self):
        """
        TEST 7 - 회귀 테스트
        기존 정상적인 single-line branch와 기존 power-flow test가 깨지지 않아야 한다.
        """
        try:
            from backend_api.tests.test_power_flow_solver import test_standard_3bus, test_excel_case25
        except ImportError:
            tests_dir = os.path.dirname(__file__)
            if tests_dir not in sys.path:
                sys.path.insert(0, tests_dir)
            from test_power_flow_solver import test_standard_3bus, test_excel_case25
        # Run standard 3bus test
        test_standard_3bus()
        # Run ac_case25 test
        test_excel_case25()


if __name__ == '__main__':
    unittest.main()

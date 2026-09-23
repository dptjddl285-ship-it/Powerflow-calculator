"""
Comprehensive Tests for Electrical Parameter Source of Truth,
Zero Series Impedance Handling, and Fallback Purge (TEST 1 to TEST 10).
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


class TestElectricalParametersAndFallbacks(unittest.TestCase):
    def setUp(self):
        self.importer = ExcelCaseImporter()
        self.solver = PowerFlowSolver(s_base=100.0, tol=1e-5, max_iter=30)

    def _create_in_memory_excel(self, branch_rows, transformer_rows=None, bus_rows=None, gen_rows=None):
        """Helper to create an in-memory Excel workbook for testing."""
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

    def test_1_normal_parameters_from_excel(self):
        """
        TEST 1 - Excel에 R, X, B가 정상 입력된 경우
        정상 주입 및 solver 계산 성공
        """
        fb, tb = 1, 2
        R, X, B = 0.02, 0.08, 0.04
        excel_bytes = self._create_in_memory_excel([
            {'From': fb, 'To': tb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B}
        ])
        parsed_excel = self.importer.parse_excel(excel_bytes)
        dummy_elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.4, 'qPu': 0.2},
            {'id': f'line_{fb}_{tb}', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}'},
        ]

        updated, summary = self.importer.apply_to_elements(dummy_elements, parsed_excel)
        line_el = next(e for e in updated if e['id'] == f'line_{fb}_{tb}')
        self.assertEqual(line_el.get('parameterStatus'), 'VALID')
        self.assertAlmostEqual(line_el['rPu'], R)
        self.assertAlmostEqual(line_el['xPu'], X)
        self.assertAlmostEqual(line_el['bPu'], B)

        # Solver execution
        result = self.solver.solve(updated)
        self.assertEqual(result['status'], 'success')
        self.assertTrue(result['converged'])
        parsed_branches = self.solver.parse_elements(updated)['branches']
        self.assertEqual(len(parsed_branches), 1)
        self.assertAlmostEqual(parsed_branches[0]['r_pu'], R)
        self.assertAlmostEqual(parsed_branches[0]['x_pu'], X)
        self.assertAlmostEqual(parsed_branches[0]['b_pu'], B)

    def test_2_zero_b_preserved_no_fallback(self):
        """
        TEST 2 - Excel에서 B=0.0인 경우
        0.0이 누락으로 처리되어 기본값으로 치환되지 않고 온전히 0.0으로 전달되는지 검증
        """
        fb, tb = 1, 2
        R, X, B = 0.015, 0.06, 0.0
        excel_bytes = self._create_in_memory_excel([
            {'From': fb, 'To': tb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B}
        ])
        parsed_excel = self.importer.parse_excel(excel_bytes)
        dummy_elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.3, 'qPu': 0.1},
            {'id': f'line_{fb}_{tb}', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}'},
        ]

        updated, summary = self.importer.apply_to_elements(dummy_elements, parsed_excel)
        line_el = next(e for e in updated if e['id'] == f'line_{fb}_{tb}')
        self.assertEqual(line_el['bPu'], 0.0)

        parsed_solver = self.solver.parse_elements(updated)
        self.assertEqual(parsed_solver['branches'][0]['b_pu'], 0.0)
        res = self.solver.solve(updated)
        self.assertTrue(res['converged'])

    def test_3_zero_r_lossless_line_no_fallback(self):
        """
        TEST 3 - Excel에서 R=0.0, X=0.05인 경우 (무손실 선로)
        R=0.0이 falsy 버그로 인해 0.01로 치환되지 않고 정확히 0.0으로 계산되는지 검증
        """
        fb, tb = 1, 2
        R, X, B = 0.0, 0.05, 0.02
        excel_bytes = self._create_in_memory_excel([
            {'From': fb, 'To': tb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B}
        ])
        parsed_excel = self.importer.parse_excel(excel_bytes)
        dummy_elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.4, 'qPu': 0.2},
            {'id': f'line_{fb}_{tb}', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}'},
        ]

        updated, summary = self.importer.apply_to_elements(dummy_elements, parsed_excel)
        line_el = next(e for e in updated if e['id'] == f'line_{fb}_{tb}')
        self.assertEqual(line_el['rPu'], 0.0)

        parsed_solver = self.solver.parse_elements(updated)
        self.assertEqual(parsed_solver['branches'][0]['r_pu'], 0.0)
        self.assertAlmostEqual(parsed_solver['branches'][0]['x_pu'], 0.05)

        res = self.solver.solve(updated)
        self.assertTrue(res['converged'])
        # Loss in pure reactance line should be strictly zero real power loss (P_loss == 0.0)
        total_loss_p = res['summary']['total_loss_p_mw']
        self.assertAlmostEqual(total_loss_p, 0.0, places=4)

    def test_4_zero_series_impedance_validation_error(self):
        """
        TEST 4 - R=0.0, X=0.0인 경우
        임의의 0.05 덮어쓰기 없이 명확한 Zero series impedance validation error 발생
        """
        fb, tb = 1, 2
        excel_bytes = self._create_in_memory_excel([
            {'From': fb, 'To': tb, 'R (pu)': 0.0, 'X (pu)': 0.0, 'B (pu)': 0.0}
        ])
        parsed_excel = self.importer.parse_excel(excel_bytes)
        dummy_elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.4, 'qPu': 0.2},
            {'id': f'line_{fb}_{tb}', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}'},
        ]

        updated, _ = self.importer.apply_to_elements(dummy_elements, parsed_excel)
        res = self.solver.solve(updated)
        self.assertEqual(res['status'], 'error')
        self.assertFalse(res['converged'])
        self.assertIn('zero series impedance', res['message'].lower())
        self.assertIn(f'{fb}', res['message'])
        self.assertIn(f'{tb}', res['message'])

    def test_5_diagram_element_preserved_when_missing_in_excel(self):
        """
        TEST 5 - CV/도면에는 선로가 존재하지만 Excel branch 시트에 데이터가 없는 경우
        도면 요소는 삭제되지 않고 유지되되, parameterStatus='MISSING' 처리되고 solver에서 차단
        """
        fb, tb = 1, 2
        # Excel only has bus and gen, but NO branch row
        excel_bytes = self._create_in_memory_excel([])
        parsed_excel = self.importer.parse_excel(excel_bytes)
        dummy_elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.4, 'qPu': 0.2},
            {'id': f'line_{fb}_{tb}', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}'},
        ]

        updated, summary = self.importer.apply_to_elements(dummy_elements, parsed_excel)
        # Topology element must NOT be deleted!
        line_el = next((e for e in updated if e['id'] == f'line_{fb}_{tb}'), None)
        self.assertIsNotNone(line_el, "Canvas topology element was erroneously deleted!")
        self.assertEqual(line_el.get('parameterStatus'), 'MISSING')
        self.assertIsNone(line_el.get('rPu'))
        self.assertIsNone(line_el.get('xPu'))

        # Simulation must be blocked with clear error
        res = self.solver.solve(updated)
        self.assertEqual(res['status'], 'error')
        self.assertFalse(res['converged'])
        self.assertIn('missing electrical parameters', res['message'].lower())

    def test_6_transformer_parameters_preserved_exactly(self):
        """
        TEST 6 - Transformer 시트에 R, X, B, tap이 있는 경우
        tap=1.0 강제 대체 없이 해당 값 그대로 solver까지 보존
        """
        fb, tb = 1, 2
        R, X, B, tap = 0.003, 0.045, 0.0, 1.04
        excel_bytes = self._create_in_memory_excel(
            branch_rows=[],
            transformer_rows=[
                {'From': fb, 'To': tb, 'R (pu)': R, 'X (pu)': X, 'B (pu)': B, 'Tap': tap}
            ]
        )
        parsed_excel = self.importer.parse_excel(excel_bytes)
        dummy_elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.3, 'qPu': 0.1},
            {'id': 'tr_1', 'type': 'transformer', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}'},
        ]

        updated, summary = self.importer.apply_to_elements(dummy_elements, parsed_excel)
        tr_el = next(e for e in updated if e['id'] == 'tr_1')
        self.assertEqual(tr_el.get('parameterStatus'), 'VALID')
        self.assertAlmostEqual(tr_el['rPu'], R)
        self.assertAlmostEqual(tr_el['xPu'], X)
        self.assertAlmostEqual(tr_el['tapRatio'], tap)

        parsed_solver = self.solver.parse_elements(updated)
        br = parsed_solver['branches'][0]
        self.assertAlmostEqual(br['r_pu'], R)
        self.assertAlmostEqual(br['x_pu'], X)
        self.assertAlmostEqual(br['tap'], tap)

        res = self.solver.solve(updated)
        self.assertTrue(res['converged'])

    def test_7_transformer_missing_parameter_rejected(self):
        """
        TEST 7 - Transformer R/X가 누락되었을 때
        0.0, 0.05 기본값을 임의 생성하지 않고 에러를 반환하는지 검증
        """
        fb, tb = 1, 2
        # Transformer row with missing R and X
        excel_bytes = self._create_in_memory_excel(
            branch_rows=[],
            transformer_rows=[
                {'From': fb, 'To': tb, 'Tap': 1.02}
            ]
        )
        parsed_excel = self.importer.parse_excel(excel_bytes)
        dummy_elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.3, 'qPu': 0.1},
            {'id': 'tr_1', 'type': 'transformer', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}'},
        ]

        updated, summary = self.importer.apply_to_elements(dummy_elements, parsed_excel)
        tr_el = next(e for e in updated if e['id'] == 'tr_1')
        self.assertEqual(tr_el.get('parameterStatus'), 'MISSING')
        self.assertIsNone(tr_el.get('rPu'))
        self.assertIsNone(tr_el.get('xPu'))

        res = self.solver.solve(updated)
        self.assertEqual(res['status'], 'error')
        self.assertIn('missing electrical parameters', res['message'].lower())

    def test_8_double_circuit_validation(self):
        """
        TEST 8 - 복회선(Double circuit) 병렬 등가 계산 파라미터 유효성 검증
        1) 개별 회선의 파라미터가 유효할 때만 병렬 등가 합성
        2) 하나라도 누락되면 합성 중단 및 solver 차단
        """
        fb, tb = 1, 2
        # Case A: One circuit has NaN R
        excel_missing = self._create_in_memory_excel([
            {'From': fb, 'To': tb, 'R (pu)': 0.02, 'X (pu)': 0.08, 'B (pu)': 0.02},
            {'From': fb, 'To': tb, 'R (pu)': None, 'X (pu)': 0.08, 'B (pu)': 0.02},
        ])
        parsed_missing = self.importer.parse_excel(excel_missing)
        br_info = parsed_missing['branches'][f'{fb}_{tb}']
        self.assertIsNone(br_info['r_pu'])

        dummy_elements = [
            {'id': f'bus_{fb}', 'type': 'bus', 'label': f'Bus {fb}', 'bus_number': fb, 'isSlack': True, 'vPu': 1.0},
            {'id': f'bus_{tb}', 'type': 'bus', 'label': f'Bus {tb}', 'bus_number': tb, 'pPu': 0.3, 'qPu': 0.1},
            {'id': f'line_{fb}_{tb}', 'type': 'line', 'startElementId': f'bus_{fb}', 'endElementId': f'bus_{tb}'},
        ]
        updated, _ = self.importer.apply_to_elements(dummy_elements, parsed_missing)
        res_missing = self.solver.solve(updated)
        self.assertEqual(res_missing['status'], 'error')

        # Case B: Both circuits valid
        excel_valid = self._create_in_memory_excel([
            {'From': fb, 'To': tb, 'R (pu)': 0.02, 'X (pu)': 0.08, 'B (pu)': 0.02},
            {'From': fb, 'To': tb, 'R (pu)': 0.02, 'X (pu)': 0.08, 'B (pu)': 0.02},
        ])
        parsed_valid = self.importer.parse_excel(excel_valid)
        br_valid = parsed_valid['branches'][f'{fb}_{tb}']
        self.assertAlmostEqual(br_valid['r_pu'], 0.01)
        self.assertAlmostEqual(br_valid['x_pu'], 0.04)
        self.assertAlmostEqual(br_valid['b_pu'], 0.04)

        updated_valid, _ = self.importer.apply_to_elements(dummy_elements, parsed_valid)
        res_valid = self.solver.solve(updated_valid)
        self.assertTrue(res_valid['converged'])

    def test_9_falsy_zero_value_not_overwritten(self):
        """
        TEST 9 - falsy 0.0 판정 버그 방지 검증
        'val or 0.01' 같은 패턴이 완전히 제거되어 rPu=0.0, bPu=0.0이 보존되는지 검증
        """
        el_zero_r = {'id': 'line_1_2', 'startElementId': 'bus_1', 'endElementId': 'bus_2', 'rPu': 0.0, 'xPu': 0.05, 'bPu': 0.0}
        extracted_r = PowerFlowSolver._extract_float(el_zero_r, "rPu", "r_pu")
        self.assertIsNotNone(extracted_r)
        self.assertEqual(extracted_r, 0.0)

        extracted_b = PowerFlowSolver._extract_float(el_zero_r, "bPu", "b_pu")
        self.assertIsNotNone(extracted_b)
        self.assertEqual(extracted_b, 0.0)

        el_missing_r = {'id': 'line_1_2', 'startElementId': 'bus_1', 'endElementId': 'bus_2', 'rPu': None, 'xPu': 0.05}
        extracted_missing = PowerFlowSolver._extract_float(el_missing_r, "rPu", "r_pu")
        self.assertIsNone(extracted_missing)

    def test_10_end_to_end_pipeline_integration(self):
        """
        TEST 10 - 전체 파이프라인(Excel parse -> apply to elements -> solver validation -> solve) 통합 테스트
        1) 3-모선 정상 계통 수렴 검증
        2) 미스매치 선로 존재 시 정확한 에러 리포트 검증
        """
        # 1. Successful 3-bus network
        bus_rows = [
            {'Bus': 1, 'Type': 3, 'Pload (MW)': 0.0, 'Qload (MVAR)': 0.0, 'Vm (pu)': 1.05, 'Va (degree)': 0.0},
            {'Bus': 2, 'Type': 2, 'Pload (MW)': 20.0, 'Qload (MVAR)': 10.0, 'Vm (pu)': 1.02, 'Va (degree)': 0.0},
            {'Bus': 3, 'Type': 1, 'Pload (MW)': 50.0, 'Qload (MVAR)': 25.0, 'Vm (pu)': 1.0, 'Va (degree)': 0.0},
        ]
        gen_rows = [
            {'Id': 1, 'Bus': 1, 'PG (MW)': 0.0, 'QG (MVAR)': 0.0, 'Voltage setpoint (pu)': 1.05, 'is_slack': True},
            {'Id': 2, 'Bus': 2, 'PG (MW)': 30.0, 'QG (MVAR)': 0.0, 'Voltage setpoint (pu)': 1.02, 'is_slack': False},
        ]
        branch_rows = [
            {'From': 1, 'To': 2, 'R (pu)': 0.02, 'X (pu)': 0.08, 'B (pu)': 0.02},
            {'From': 2, 'To': 3, 'R (pu)': 0.03, 'X (pu)': 0.12, 'B (pu)': 0.03},
        ]
        transformer_rows = [
            {'From': 1, 'To': 3, 'R (pu)': 0.005, 'X (pu)': 0.05, 'B (pu)': 0.0, 'Tap': 1.02}
        ]
        excel_bytes = self._create_in_memory_excel(
            branch_rows=branch_rows,
            transformer_rows=transformer_rows,
            bus_rows=bus_rows,
            gen_rows=gen_rows
        )
        parsed_excel = self.importer.parse_excel(excel_bytes)

        canvas_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': 'Bus 1', 'bus_number': 1, 'isSlack': True, 'vPu': 1.05},
            {'id': 'bus_2', 'type': 'bus', 'label': 'Bus 2', 'bus_number': 2, 'pPu': 0.2, 'qPu': 0.1},
            {'id': 'bus_3', 'type': 'bus', 'label': 'Bus 3', 'bus_number': 3, 'pPu': 0.5, 'qPu': 0.25},
            {'id': 'gen_1', 'type': 'generator', 'parentBusId': 'bus_1', 'isSlack': True},
            {'id': 'gen_2', 'type': 'generator', 'parentBusId': 'bus_2', 'pPu': 0.3, 'vPu': 1.02},
            {'id': 'line_1_2', 'type': 'line', 'startElementId': 'bus_1', 'endElementId': 'bus_2'},
            {'id': 'line_2_3', 'type': 'line', 'startElementId': 'bus_2', 'endElementId': 'bus_3'},
            {'id': 'tr_1_3', 'type': 'transformer', 'startElementId': 'bus_1', 'endElementId': 'bus_3'},
        ]

        updated, summary = self.importer.apply_to_elements(canvas_elements, parsed_excel)
        self.assertEqual(summary['applied_counts']['line'], 2)
        self.assertEqual(summary['applied_counts']['transformer'], 1)

        result = self.solver.solve(updated)
        self.assertTrue(result['converged'])
        self.assertEqual(result['slack_bus'], 1)
        self.assertEqual(len(result['line_results']), 3)

        # 2. Add an unmapped line on canvas (e.g. Line 1-4 to a non-existent bus or unmapped branch)
        canvas_with_surplus = list(updated) + [
            {'id': 'line_extra', 'type': 'line', 'label': 'Line 1-3', 'startElementId': 'bus_1', 'endElementId': 'bus_3'}
        ]
        updated_surplus, _ = self.importer.apply_to_elements(canvas_with_surplus, parsed_excel)
        extra_el = next(e for e in updated_surplus if e['id'] == 'line_extra')
        # Line 1-3 is a transformer in Excel, not a line in branch sheet!
        self.assertEqual(extra_el.get('parameterStatus'), 'MISSING')


if __name__ == '__main__':
    unittest.main()

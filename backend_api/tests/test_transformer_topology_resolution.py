# -*- coding: utf-8 -*-
import unittest
import os
import sys
import pandas as pd

backend_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

from core.excel_case_importer import ExcelCaseImporter
from core.power_flow_solver import PowerFlowSolver


class TestTransformerTopologyResolution(unittest.TestCase):
    def setUp(self):
        self.importer = ExcelCaseImporter()
        self.solver = PowerFlowSolver(s_base=100.0, tol=1e-5, max_iter=30)
        self.sample_excel_path = os.path.join(
            backend_dir, 'sample_cases', 'case24_ieee_rts_diagram_aligned.xlsx'
        )

    def test_1_two_port_simple_transformer(self):
        """
        TEST 1: 2-port simple transformer (1 <-> 2 -> 1 branch)
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PQ', 'pload_pu': 0.5, 'qload_pu': 0.2},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {
                '1_2': {
                    'from_bus': 1,
                    'to_bus': 2,
                    'r_pu': 0.01,
                    'x_pu': 0.05,
                    'b_pu': 0.0,
                    'tap': 1.03,
                }
            }
        }

        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'gen_1', 'type': 'generator', 'parentBusId': 'bus_1', 'bus_number': 1},
            {'id': 'load_2', 'type': 'load', 'parentBusId': 'bus_2', 'bus_number': 2},
            {'id': 'tr_1_2', 'type': 'transformer', 'startElementId': 'bus_1', 'endElementId': 'bus_2', 'label': 'TR_1_2'},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)
        parsed = self.solver.parse_elements(updated_elements)

        tr_branches = [b for b in parsed['branches'] if b.get('is_transformer')]
        self.assertEqual(len(tr_branches), 1)
        self.assertEqual(tr_branches[0]['from_bus'], 1)
        self.assertEqual(tr_branches[0]['to_bus'], 2)
        self.assertAlmostEqual(tr_branches[0]['tap'], 1.03)
        self.assertAlmostEqual(tr_branches[0]['r_pu'], 0.01)
        self.assertAlmostEqual(tr_branches[0]['x_pu'], 0.05)

    def test_2_multi_bus_transformer_topology(self):
        """
        TEST 2: Multi-bus transformer topology ({9, 10} <-> {11, 12} with 4 Excel pairs -> 4 branches)
        Zero auto-created canvas components.
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 9,
            'buses': {
                '9': {'bus_number': 9, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '10': {'bus_number': 10, 'type': 'PQ', 'pload_pu': 0.1, 'qload_pu': 0.05},
                '11': {'bus_number': 11, 'type': 'PQ', 'pload_pu': 0.2, 'qload_pu': 0.1},
                '12': {'bus_number': 12, 'type': 'PQ', 'pload_pu': 0.3, 'qload_pu': 0.15},
            },
            'generators': {
                '9': {'bus_number': 9, 'is_slack': True, 'pg_mw': 60.0, 'pg_pu': 0.6, 'qg_pu': 0.3, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {
                '9_11': {'from_bus': 9, 'to_bus': 11, 'r_pu': 0.002, 'x_pu': 0.08, 'b_pu': 0.0, 'tap': 1.03},
                '10_11': {'from_bus': 10, 'to_bus': 11, 'r_pu': 0.002, 'x_pu': 0.08, 'b_pu': 0.0, 'tap': 1.02},
                '9_12': {'from_bus': 9, 'to_bus': 12, 'r_pu': 0.002, 'x_pu': 0.08, 'b_pu': 0.0, 'tap': 1.03},
                '10_12': {'from_bus': 10, 'to_bus': 12, 'r_pu': 0.002, 'x_pu': 0.08, 'b_pu': 0.0, 'tap': 1.02},
            }
        }

        # Substation topology: TR_A connects {9, 10, 11}, TR_B connects {9, 10, 12}
        diagram_elements = [
            {'id': 'bus_9', 'type': 'bus', 'label': '9', 'bus_number': 9, 'isSlack': True},
            {'id': 'bus_10', 'type': 'bus', 'label': '10', 'bus_number': 10},
            {'id': 'bus_11', 'type': 'bus', 'label': '11', 'bus_number': 11},
            {'id': 'bus_12', 'type': 'bus', 'label': '12', 'bus_number': 12},
            {'id': 'gen_9', 'type': 'generator', 'parentBusId': 'bus_9', 'bus_number': 9},
            # TR_A
            {'id': 'tr_A', 'type': 'transformer', 'label': 'TR_A'},
            {'id': 'lead_A_9', 'type': 'line', 'startElementId': 'tr_A', 'endElementId': 'bus_9'},
            {'id': 'lead_A_10', 'type': 'line', 'startElementId': 'tr_A', 'endElementId': 'bus_10'},
            {'id': 'lead_A_11', 'type': 'line', 'startElementId': 'tr_A', 'endElementId': 'bus_11'},
            # TR_B
            {'id': 'tr_B', 'type': 'transformer', 'label': 'TR_B'},
            {'id': 'lead_B_9', 'type': 'line', 'startElementId': 'tr_B', 'endElementId': 'bus_9'},
            {'id': 'lead_B_10', 'type': 'line', 'startElementId': 'tr_B', 'endElementId': 'bus_10'},
            {'id': 'lead_B_12', 'type': 'line', 'startElementId': 'tr_B', 'endElementId': 'bus_12'},
        ]
        initial_count = len(diagram_elements)

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # Ensure no canvas elements were auto-created
        self.assertEqual(len(updated_elements), initial_count)

        parsed = self.solver.parse_elements(updated_elements)
        tr_branches = [b for b in parsed['branches'] if b.get('is_transformer')]
        self.assertEqual(len(tr_branches), 4)

        pairs = {tuple(sorted([b['from_bus'], b['to_bus']])) for b in tr_branches}
        self.assertEqual(pairs, {(9, 11), (10, 11), (9, 12), (10, 12)})

    def test_3_partial_excel_pairs(self):
        """
        TEST 3: Partial Excel pairs (only 9-11, 10-12 in Excel -> 2 branches; 9-12, 10-11 NOT created)
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 9,
            'buses': {
                '9': {'bus_number': 9, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '10': {'bus_number': 10, 'type': 'PQ', 'pload_pu': 0.1, 'qload_pu': 0.05},
                '11': {'bus_number': 11, 'type': 'PQ', 'pload_pu': 0.2, 'qload_pu': 0.1},
                '12': {'bus_number': 12, 'type': 'PQ', 'pload_pu': 0.3, 'qload_pu': 0.15},
            },
            'generators': {
                '9': {'bus_number': 9, 'is_slack': True, 'pg_mw': 60.0, 'pg_pu': 0.6, 'qg_pu': 0.3, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            # Only 2 pairs present in Excel!
            'transformers': {
                '9_11': {'from_bus': 9, 'to_bus': 11, 'r_pu': 0.002, 'x_pu': 0.08, 'b_pu': 0.0, 'tap': 1.03},
                '10_12': {'from_bus': 10, 'to_bus': 12, 'r_pu': 0.002, 'x_pu': 0.08, 'b_pu': 0.0, 'tap': 1.02},
            }
        }

        # Multi-bus transformer connecting {9, 10, 11, 12}
        diagram_elements = [
            {'id': 'bus_9', 'type': 'bus', 'label': '9', 'bus_number': 9, 'isSlack': True},
            {'id': 'bus_10', 'type': 'bus', 'label': '10', 'bus_number': 10},
            {'id': 'bus_11', 'type': 'bus', 'label': '11', 'bus_number': 11},
            {'id': 'bus_12', 'type': 'bus', 'label': '12', 'bus_number': 12},
            {'id': 'tr_multi', 'type': 'transformer', 'label': 'TR_MULTI'},
            {'id': 'lead_9', 'type': 'line', 'startElementId': 'tr_multi', 'endElementId': 'bus_9'},
            {'id': 'lead_10', 'type': 'line', 'startElementId': 'tr_multi', 'endElementId': 'bus_10'},
            {'id': 'lead_11', 'type': 'line', 'startElementId': 'tr_multi', 'endElementId': 'bus_11'},
            {'id': 'lead_12', 'type': 'line', 'startElementId': 'tr_multi', 'endElementId': 'bus_12'},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)
        parsed = self.solver.parse_elements(updated_elements)

        tr_branches = [b for b in parsed['branches'] if b.get('is_transformer')]
        self.assertEqual(len(tr_branches), 2)
        pairs = {tuple(sorted([b['from_bus'], b['to_bus']])) for b in tr_branches}
        self.assertEqual(pairs, {(9, 11), (10, 12)})
        self.assertNotIn((9, 12), pairs)
        self.assertNotIn((10, 11), pairs)

    def test_4_missing_bus_validation(self):
        """
        TEST 4: Missing bus -> validation error, no auto-created bus or transformer
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {
                '1_999': {'from_bus': 1, 'to_bus': 999, 'r_pu': 0.01, 'x_pu': 0.05, 'b_pu': 0.0, 'tap': 1.0}
            }
        }

        # Bus 999 does not exist in diagram
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'tr_bad', 'type': 'transformer', 'label': 'TR_1_999', 'from_bus': 1, 'to_bus': 999, 'rPu': 0.01, 'xPu': 0.05},
        ]

        parsed = self.solver.parse_elements(diagram_elements)
        # Validation error must be reported
        self.assertNotIn(999, parsed['buses'])
        # No branches between 1 and 999 should be admitted
        self.assertEqual(len(parsed['branches']), 0)

    def test_5_duplicate_prevention(self):
        """
        TEST 5: Duplicate prevention -> multiple lead paths -> 1 electrical branch per Excel row
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PQ', 'pload_pu': 0.5, 'qload_pu': 0.2},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {},
            'transformers': {
                '1_2': {'from_bus': 1, 'to_bus': 2, 'r_pu': 0.01, 'x_pu': 0.05, 'b_pu': 0.0, 'tap': 1.0}
            }
        }

        # 3 redundant leads to Bus 1, and 2 redundant leads to Bus 2
        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'tr_1', 'type': 'transformer', 'label': 'TR_1'},
            {'id': 'lead_1a', 'type': 'line', 'startElementId': 'tr_1', 'endElementId': 'bus_1'},
            {'id': 'lead_1b', 'type': 'line', 'startElementId': 'tr_1', 'endElementId': 'bus_1'},
            {'id': 'lead_1c', 'type': 'line', 'startElementId': 'tr_1', 'endElementId': 'bus_1'},
            {'id': 'lead_2a', 'type': 'line', 'startElementId': 'tr_1', 'endElementId': 'bus_2'},
            {'id': 'lead_2b', 'type': 'line', 'startElementId': 'tr_1', 'endElementId': 'bus_2'},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)
        parsed = self.solver.parse_elements(updated_elements)

        tr_branches = [b for b in parsed['branches'] if b.get('is_transformer')]
        self.assertEqual(len(tr_branches), 1)
        self.assertEqual(tr_branches[0]['from_bus'], 1)
        self.assertEqual(tr_branches[0]['to_bus'], 2)

    def test_6_transformer_lead_exclusion(self):
        """
        TEST 6: Transformer lead exclusion -> leads marked is_transformer_lead: True, excluded from electrical lines
        """
        excel_data = {
            'sbase_mva': 100.0,
            'slack_bus_number': 1,
            'buses': {
                '1': {'bus_number': 1, 'type': 'Swing', 'pload_pu': 0.0, 'qload_pu': 0.0},
                '2': {'bus_number': 2, 'type': 'PQ', 'pload_pu': 0.5, 'qload_pu': 0.2},
            },
            'generators': {
                '1': {'bus_number': 1, 'is_slack': True, 'pg_mw': 50.0, 'pg_pu': 0.5, 'qg_pu': 0.2, 'voltage_setpoint': 1.0},
            },
            'branches': {
                '1_2': {'from_bus': 1, 'to_bus': 2, 'r_pu': 0.02, 'x_pu': 0.08, 'b_pu': 0.02}
            },
            'transformers': {
                '1_2': {'from_bus': 1, 'to_bus': 2, 'r_pu': 0.01, 'x_pu': 0.05, 'b_pu': 0.0, 'tap': 1.05}
            }
        }

        diagram_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1, 'isSlack': True},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2, 'isSlack': False},
            {'id': 'tr_1', 'type': 'transformer', 'label': 'TR_1'},
            {'id': 'lead_1', 'type': 'line', 'startElementId': 'tr_1', 'endElementId': 'bus_1'},
            {'id': 'lead_2', 'type': 'line', 'startElementId': 'tr_1', 'endElementId': 'bus_2'},
        ]

        updated_elements, summary = self.importer.apply_to_elements(diagram_elements, excel_data)

        # Check lead flags
        for el in updated_elements:
            if el['id'] in ('lead_1', 'lead_2'):
                self.assertTrue(el.get('is_transformer_lead'))
                self.assertTrue(el.get('isTransformerLead'))
                self.assertFalse(el.get('electricalBranch'))

        parsed = self.solver.parse_elements(updated_elements)
        non_tr_lines = [b for b in parsed['branches'] if not b.get('is_transformer')]
        # Lead lines must NOT appear as regular lines
        self.assertEqual(len(non_tr_lines), 0)

        tr_branches = [b for b in parsed['branches'] if b.get('is_transformer')]
        self.assertEqual(len(tr_branches), 1)

    def test_7_case24_ieee_rts_regression(self):
        """
        TEST 7: case24_ieee_rts_diagram_aligned.xlsx regression
        All 5 transformer branches present; Newton-Raphson converges to:
        - Slack Bus 13 P approx 188.2517 MW, Q approx 94.6001 MVAR
        - Bus 7: V approx 1.0250, theta approx -6.9549 deg, Qg approx 38.1735 MVAR
        - Bus 8: V approx 1.0010, theta approx -10.7761 deg
        - Bus 9: V approx 1.0085, theta approx -7.3293 deg
        - Bus 10: V approx 1.0591, theta approx -9.4200 deg
        - Bus 14: V approx 0.9908
        - Bus 15: Qg approx -6.9768 MVAR
        """
        if not os.path.exists(self.sample_excel_path):
            self.skipTest(f"Excel file not found at {self.sample_excel_path}")

        with open(self.sample_excel_path, 'rb') as f:
            excel_data = self.importer.parse_excel(f.read())

        wb = pd.read_excel(self.sample_excel_path, sheet_name=None)
        bus_df = wb['bus']
        gen_df = wb['generator']
        branch_df = wb['branch']
        trans_df = wb['transformer']

        elements = []
        for _, r in bus_df.iterrows():
            b_num = int(r['Bus'])
            elements.append({
                'id': f'bus_{b_num}',
                'type': 'bus',
                'label': str(b_num),
                'bus_number': b_num,
                'isSlack': (b_num == excel_data['slack_bus_number']),
            })

        for _, r in gen_df.iterrows():
            b_num = int(r['Bus'])
            elements.append({
                'id': f'gen_{b_num}',
                'type': 'generator',
                'parentBusId': f'bus_{b_num}',
                'bus_number': b_num,
                'label': f'G_{b_num}',
            })

        for _, r in bus_df.iterrows():
            b_num = int(r['Bus'])
            if float(r.get('Pload (MW)', 0)) > 0 or float(r.get('Qload (MVAR)', 0)) > 0:
                elements.append({
                    'id': f'load_{b_num}',
                    'type': 'load',
                    'parentBusId': f'bus_{b_num}',
                    'bus_number': b_num,
                    'label': f'L_{b_num}',
                })

        trans_pairs_all = {tuple(sorted([int(r['From']), int(r['To'])])) for _, r in trans_df.iterrows()}
        seen_line_pairs = set()
        for idx, r in branch_df.iterrows():
            fb, tb = int(r['From']), int(r['To'])
            pair = tuple(sorted([fb, tb]))
            if pair in trans_pairs_all or pair in seen_line_pairs:
                continue
            seen_line_pairs.add(pair)
            elements.append({
                'id': f'line_{fb}_{tb}',
                'type': 'line',
                'startElementId': f'bus_{fb}',
                'endElementId': f'bus_{tb}',
                'label': f'Line {fb}-{tb}',
            })

        # TR_41 connects {9, 10, 11}
        elements.append({'id': 'tr_41', 'type': 'transformer', 'label': 'TR_41'})
        elements.append({'id': 'lead_41_9', 'type': 'line', 'startElementId': 'tr_41', 'endElementId': 'bus_9'})
        elements.append({'id': 'lead_41_10', 'type': 'line', 'startElementId': 'tr_41', 'endElementId': 'bus_10'})
        elements.append({'id': 'lead_41_11', 'type': 'line', 'startElementId': 'tr_41', 'endElementId': 'bus_11'})

        # TR_43 connects {9, 10, 12}
        elements.append({'id': 'tr_43', 'type': 'transformer', 'label': 'TR_43'})
        elements.append({'id': 'lead_43_9', 'type': 'line', 'startElementId': 'tr_43', 'endElementId': 'bus_9'})
        elements.append({'id': 'lead_43_10', 'type': 'line', 'startElementId': 'tr_43', 'endElementId': 'bus_10'})
        elements.append({'id': 'lead_43_12', 'type': 'line', 'startElementId': 'tr_43', 'endElementId': 'bus_12'})

        # TR_42 connects {3, 24}
        elements.append({'id': 'tr_42', 'type': 'transformer', 'label': 'TR_42'})
        elements.append({'id': 'lead_42_3', 'type': 'line', 'startElementId': 'tr_42', 'endElementId': 'bus_3'})
        elements.append({'id': 'lead_42_24', 'type': 'line', 'startElementId': 'tr_42', 'endElementId': 'bus_24'})

        # 1. Verification of discrepancies: zero missing transformer branches
        discrepancies = self.importer.compare_elements_with_excel(elements, excel_data)
        missing_br = discrepancies.get('missing_branches') or []
        missing_tr = [p for p in missing_br if p in [(3, 24), (9, 11), (9, 12), (10, 11), (10, 12)]]
        self.assertEqual(len(missing_tr), 0)

        # 2. Apply parameters
        updated_elements, summary = self.importer.apply_to_elements(elements, excel_data)
        parsed = self.solver.parse_elements(updated_elements)

        tr_branches = [b for b in parsed['branches'] if b.get('is_transformer')]
        self.assertEqual(len(tr_branches), 5)
        tr_pairs = {tuple(sorted([b['from_bus'], b['to_bus']])) for b in tr_branches}
        self.assertEqual(tr_pairs, {(3, 24), (9, 11), (9, 12), (10, 11), (10, 12)})

        # 3. Power flow solution
        res = self.solver.solve(updated_elements)
        self.assertTrue(res.get('converged'))

        res_by_bus = {r['bus']: r for r in res['bus_results']}

        # Slack Bus 13: P approx 188.2517 MW, Q approx 94.6001 MVAR
        slack = res_by_bus[13]
        self.assertAlmostEqual(slack['pgen'], 188.2517, delta=0.5)
        self.assertAlmostEqual(slack['qgen'], 94.6001, delta=0.5)

        # Bus 7: V approx 1.0250, theta approx -6.9549 deg, Qg approx 38.1735 MVAR
        b7 = res_by_bus[7]
        self.assertAlmostEqual(b7['volt'], 1.0250, delta=0.005)
        self.assertAlmostEqual(b7['angle'], -6.9549, delta=0.1)
        self.assertAlmostEqual(b7['qgen'], 38.1735, delta=0.5)

        # Bus 8: V approx 1.0010, theta approx -10.7761 deg
        b8 = res_by_bus[8]
        self.assertAlmostEqual(b8['volt'], 1.0010, delta=0.005)
        self.assertAlmostEqual(b8['angle'], -10.7761, delta=0.1)

        # Bus 9: V approx 1.0085, theta approx -7.3293 deg
        b9 = res_by_bus[9]
        self.assertAlmostEqual(b9['volt'], 1.0085, delta=0.005)
        self.assertAlmostEqual(b9['angle'], -7.3293, delta=0.1)

        # Bus 10: V approx 1.0591, theta approx -9.4200 deg
        b10 = res_by_bus[10]
        self.assertAlmostEqual(b10['volt'], 1.0591, delta=0.005)
        self.assertAlmostEqual(b10['angle'], -9.4200, delta=0.1)

        # Bus 14: V approx 0.9908
        b14 = res_by_bus[14]
        self.assertAlmostEqual(b14['volt'], 0.9908, delta=0.005)

        # Bus 15: Qg approx -6.9768 MVAR
        b15 = res_by_bus[15]
        self.assertAlmostEqual(b15['qgen'], -6.9768, delta=0.5)


if __name__ == '__main__':
    unittest.main()

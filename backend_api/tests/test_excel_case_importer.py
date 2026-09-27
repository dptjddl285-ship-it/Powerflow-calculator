import unittest
import os
import sys
from copy import deepcopy

backend_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

from core.excel_case_importer import ExcelCaseImporter
from core.power_flow_solver import PowerFlowSolver

class TestExcelCaseImporter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.importer = ExcelCaseImporter()
        sample_excel = os.path.join(backend_dir, 'sample_cases', 'ac_case25.xlsx')
        if os.path.exists(sample_excel):
            cls.excel_path = sample_excel
        else:
            cls.excel_path = r"C:\Users\dptjd\Downloads\84_240909111503033 (3)\ac_case25 - 복사본.xlsx"

    def test_parse_ac_case25_excel(self):
        if not os.path.exists(self.excel_path):
            self.skipTest(f"Excel file not found at {self.excel_path}")

        data = self.importer.parse_excel(self.excel_path)
        self.assertEqual(data['slack_bus_number'], 13)
        self.assertEqual(data['total_buses'], 25)
        self.assertGreater(data['total_generators'], 0)
        self.assertGreater(data['total_branches'], 0)

        # Bus 13 is Slack
        bus13 = data['buses'].get(13) or data['buses'].get('13')
        self.assertTrue(bus13['is_slack'])
        self.assertEqual(bus13['type'], 'Swing')
        self.assertAlmostEqual(bus13['pload_mw'], 265.0)
        self.assertAlmostEqual(bus13['pload_pu'], 2.65)

        # Bus 1 is PV
        bus1 = data['buses'].get(1) or data['buses'].get('1')
        self.assertFalse(bus1['is_slack'])
        self.assertEqual(bus1['type'], 'PV')

        # Generator at Bus 13 is Slack
        gen13 = data['generators'].get(13) or data['generators'].get('13')
        self.assertTrue(gen13['is_slack'])

    def test_apply_to_drawing_elements(self):
        if not os.path.exists(self.excel_path):
            self.skipTest(f"Excel file not found at {self.excel_path}")

        data = self.importer.parse_excel(self.excel_path)
        dummy_elements = [
            {'id': 'bus_13', 'type': 'bus', 'label': '13', 'isSlack': False},
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'isSlack': False},
            {'id': 'gen_13', 'type': 'generator', 'parentBusId': 'bus_13', 'label': 'G_13'},
            {'id': 'load_13', 'type': 'load', 'parentBusId': 'bus_13', 'label': 'Load_13'},
            {'id': 'line_1_2', 'type': 'line', 'startElementId': 'bus_1', 'endElementId': 'bus_2'}
        ]

        updated, summary = self.importer.apply_to_elements(dummy_elements, data)
        self.assertEqual(summary['slack_bus_number'], 13)

        # Bus 13 should now be Slack
        bus13_el = next(e for e in updated if e['id'] == 'bus_13')
        self.assertTrue(bus13_el['isSlack'])
        self.assertAlmostEqual(bus13_el['pPu'], 2.65)

        # Gen 13 should now be Slack
        gen13_el = next(e for e in updated if e['id'] == 'gen_13')
        self.assertTrue(gen13_el['isSlack'])
        self.assertIn('Slack', gen13_el['label'])

        # Load 13 should have Pload
        load13_el = next(e for e in updated if e['id'] == 'load_13')
        self.assertAlmostEqual(load13_el['pPu'], 2.65)

    def test_apply_to_transformer_leads(self):
        if not os.path.exists(self.excel_path):
            self.skipTest(f"Excel file not found at {self.excel_path}")

        data = self.importer.parse_excel(self.excel_path)
        # Diagram with Bus 3 and Bus 24 connected through a transformer node and 2 lead lines
        dummy_elements = [
            {'id': 'bus_3', 'type': 'bus', 'label': 'Bus 3', 'bus_number': 3},
            {'id': 'bus_24', 'type': 'bus', 'label': 'Bus 24', 'bus_number': 24},
            {'id': 'transformer_43', 'type': 'transformer', 'label': 'transformer_43'},
            {'id': 'L1', 'type': 'line', 'startElementId': 'bus_3', 'endElementId': 'transformer_43'},
            {'id': 'L18', 'type': 'line', 'startElementId': 'transformer_43', 'endElementId': 'bus_24'},
        ]

        updated, summary = self.importer.apply_to_elements(dummy_elements, data)
        self.assertEqual(summary['applied_counts']['transformer'], 1)

        trans_el = next(e for e in updated if e['id'] == 'transformer_43')
        self.assertAlmostEqual(trans_el['tapRatio'], 1.03)
        self.assertAlmostEqual(trans_el['rPu'], 0.0023)
        self.assertAlmostEqual(trans_el['xPu'], 0.0839)
        self.assertIn('3-24', trans_el['label'])

        line1 = next(e for e in updated if e['id'] == 'L1')
        self.assertTrue(line1.get('is_transformer_lead'))
        self.assertEqual(line1.get('rPu'), 0.0)

        line2 = next(e for e in updated if e['id'] == 'L18')
        self.assertTrue(line2.get('is_transformer_lead'))
        self.assertEqual(line2.get('rPu'), 0.0)

        # Solver must parse exactly ONE electrical branch (the transformer itself)
        solver = PowerFlowSolver()
        parsed = solver.parse_elements(updated)
        self.assertEqual(len(parsed['branches']), 1)
        br = parsed['branches'][0]
        self.assertEqual({br['from_bus'], br['to_bus']}, {3, 24})
        self.assertAlmostEqual(br['tap'], 1.03)
        self.assertAlmostEqual(br['r_pu'], 0.0023)
        self.assertAlmostEqual(br['x_pu'], 0.0839)

    def test_apply_to_generator_and_load_leads(self):
        if not os.path.exists(self.excel_path):
            self.skipTest(f"Excel file not found at {self.excel_path}")

        data = self.importer.parse_excel(self.excel_path)
        dummy_elements = [
            {'id': 'bus_1', 'type': 'bus', 'label': '1', 'bus_number': 1},
            {'id': 'bus_2', 'type': 'bus', 'label': '2', 'bus_number': 2},
            {'id': 'node_gen_1', 'type': 'generator', 'label': 'G_1', 'parentBusId': 'bus_1'},
            {'id': 'node_load_2', 'type': 'load', 'label': 'Load_2', 'parentBusId': 'bus_2'},
            # Line connected via connected_to
            {'id': 'line_lead_g1', 'type': 'line', 'connected_to': ['bus_1', 'node_gen_1']},
            # Line connected via startElementId and endElementId
            {'id': 'line_lead_l2', 'type': 'line', 'startElementId': 'bus_2', 'endElementId': 'node_load_2'},
        ]

        updated, summary = self.importer.apply_to_elements(dummy_elements, data)

        line_g1 = next(e for e in updated if e['id'] == 'line_lead_g1')
        self.assertEqual(line_g1['rPu'], 0.0)
        self.assertEqual(line_g1['xPu'], 0.0)
        self.assertGreater(line_g1['pPu'], 0.0)
        self.assertIn('Line Bus 1 ↔ G_1', line_g1['label'])

        line_l2 = next(e for e in updated if e['id'] == 'line_lead_l2')
        self.assertEqual(line_l2['rPu'], 0.0)
        self.assertEqual(line_l2['xPu'], 0.0)
        self.assertGreater(line_l2['pPu'], 0.0)
        self.assertIn('Line Bus 2 ↔ Load_2', line_l2['label'])

    def _create_minimal_excel_bytes(self, param_df=None):
        import io
        import pandas as pd
        buf = io.BytesIO()
        with pd.ExcelWriter(buf, engine='openpyxl') as writer:
            if param_df is not None:
                param_df.to_excel(writer, sheet_name='param', index=False)
            bus_df = pd.DataFrame({
                'bus': [1, 2],
                'type': ['Swing', 'PQ'],
                'pload': [100.0, 50.0],
                'qload': [10.0, 5.0]
            })
            bus_df.to_excel(writer, sheet_name='bus', index=False)
        buf.seek(0)
        return buf

    def test_sbase_parsing_100(self):
        import pandas as pd
        buf = self._create_minimal_excel_bytes(pd.DataFrame({'sbase (MVA)': [100]}))
        data = self.importer.parse_excel(buf)
        self.assertEqual(data['sbase_mva'], 100.0)
        self.assertAlmostEqual(data['buses']['1']['pload_pu'], 1.0)
        self.assertAlmostEqual(data['buses']['2']['pload_pu'], 0.5)

    def test_sbase_parsing_50(self):
        import pandas as pd
        buf = self._create_minimal_excel_bytes(pd.DataFrame({'sbase (MVA)': [50]}))
        data = self.importer.parse_excel(buf)
        self.assertEqual(data['sbase_mva'], 50.0)
        # 100 MW / 50 MVA = 2.0 pu
        self.assertAlmostEqual(data['buses']['1']['pload_pu'], 2.0)
        # 50 MW / 50 MVA = 1.0 pu
        self.assertAlmostEqual(data['buses']['2']['pload_pu'], 1.0)

    def test_sbase_parsing_200(self):
        import pandas as pd
        buf = self._create_minimal_excel_bytes(pd.DataFrame({'sbase (MVA)': [200]}))
        data = self.importer.parse_excel(buf)
        self.assertEqual(data['sbase_mva'], 200.0)
        # 100 MW / 200 MVA = 0.5 pu
        self.assertAlmostEqual(data['buses']['1']['pload_pu'], 0.5)
        # 50 MW / 200 MVA = 0.25 pu
        self.assertAlmostEqual(data['buses']['2']['pload_pu'], 0.25)

    def test_sbase_key_value_format(self):
        import pandas as pd
        buf = self._create_minimal_excel_bytes(pd.DataFrame({'Parameter': ['sbase'], 'Value': [50]}))
        data = self.importer.parse_excel(buf)
        self.assertEqual(data['sbase_mva'], 50.0)

    def test_sbase_parsing_missing_sheet(self):
        buf = self._create_minimal_excel_bytes(param_df=None)
        data = self.importer.parse_excel(buf)
        self.assertEqual(data['sbase_mva'], 100.0)

    def test_verified_sld_comparison_uses_explicit_bus_numbers_and_does_not_mutate(self):
        elements = [
            {'id': 'node_alpha', 'type': 'bus', 'label': 'Bus 1', 'bus_number': 1},
            {'id': 'node_beta', 'type': 'bus', 'label': 'Bus 2', 'bus_number': 2},
            {
                'id': 'edge_alpha_beta',
                'type': 'line',
                'connected_to': ['node_alpha', 'node_beta'],
                'label': 'verified edge',
            },
        ]
        excel_data = {
            'buses': {'1': {}, '2': {}},
            'generators': {},
            'branches': {'1_2': {'from_bus': 1, 'to_bus': 2}},
            'transformers': {},
        }
        original = deepcopy(elements)

        report = self.importer.compare_elements_with_excel(
            elements,
            excel_data,
            structured_bus_numbers_only=True,
        )

        self.assertTrue(report['is_matched'], report['discrepancies'])
        self.assertEqual(elements, original)

    def test_verified_sld_comparison_does_not_infer_pairs_from_overconnected_transformers(self):
        elements = [
            {'id': f'bus_{number}', 'type': 'bus', 'bus_number': number}
            for number in (9, 10, 11, 12)
        ] + [
            {'id': 'trans_9_11', 'type': 'transformer'},
            {'id': 'trans_10_12', 'type': 'transformer'},
            {'id': 'lead_9_9_11', 'type': 'line', 'startElementId': 'bus_9', 'endElementId': 'trans_9_11'},
            {'id': 'lead_10_9_11', 'type': 'line', 'startElementId': 'bus_10', 'endElementId': 'trans_9_11'},
            {'id': 'lead_11_9_11', 'type': 'line', 'startElementId': 'trans_9_11', 'endElementId': 'bus_11'},
            {'id': 'lead_9_10_12', 'type': 'line', 'startElementId': 'bus_9', 'endElementId': 'trans_10_12'},
            {'id': 'lead_10_10_12', 'type': 'line', 'startElementId': 'bus_10', 'endElementId': 'trans_10_12'},
            {'id': 'lead_12_10_12', 'type': 'line', 'startElementId': 'trans_10_12', 'endElementId': 'bus_12'},
        ]
        excel_data = {
            'buses': {str(number): {} for number in (9, 10, 11, 12)},
            'generators': {},
            'branches': {
                '9_12': {'from_bus': 9, 'to_bus': 12},
                '10_11': {'from_bus': 10, 'to_bus': 11},
            },
            'transformers': {
                '9_11': {'from_bus': 9, 'to_bus': 11},
                '10_12': {'from_bus': 10, 'to_bus': 12},
            },
        }

        report = self.importer.compare_elements_with_excel(
            elements,
            excel_data,
            structured_bus_numbers_only=True,
        )

        self.assertFalse(report['is_matched'])
        self.assertEqual(
            set(report['details']['unmapped_branches']),
            set(),
        )
        self.assertEqual(
            set(map(tuple, report['details']['missing_branches'])),
            {(9, 12), (10, 11)},
        )

    def test_verified_sld_comparison_accepts_exact_two_bus_transformer(self):
        elements = [
            {'id': 'bus_3', 'type': 'bus', 'bus_number': 3},
            {'id': 'bus_24', 'type': 'bus', 'bus_number': 24},
            {'id': 'trans_3_24', 'type': 'transformer'},
            {'id': 'lead_3', 'type': 'line', 'startElementId': 'bus_3', 'endElementId': 'trans_3_24'},
            {'id': 'lead_24', 'type': 'line', 'startElementId': 'trans_3_24', 'endElementId': 'bus_24'},
        ]
        excel_data = {
            'buses': {'3': {}, '24': {}},
            'generators': {},
            'branches': {},
            'transformers': {
                '3_24': {'from_bus': 3, 'to_bus': 24},
            },
        }

        report = self.importer.compare_elements_with_excel(
            elements,
            excel_data,
            structured_bus_numbers_only=True,
        )

        self.assertTrue(report['is_matched'], report['discrepancies'])

    def test_verified_sld_comparison_never_infers_bus_number_from_id_or_label(self):
        elements = [
            {'id': 'bus_17', 'type': 'bus', 'label': 'Bus 17'},
            {'id': 'bus_18', 'type': 'bus', 'label': 'Bus 18'},
            {
                'id': 'line_17_18',
                'type': 'line',
                'connected_to': ['bus_17', 'bus_18'],
                'label': 'Line 17-18',
            },
        ]
        excel_data = {
            'buses': {'17': {}, '18': {}},
            'generators': {},
            'branches': {'17_18': {'from_bus': 17, 'to_bus': 18}},
            'transformers': {},
        }

        report = self.importer.compare_elements_with_excel(
            elements,
            excel_data,
            structured_bus_numbers_only=True,
        )

        self.assertFalse(report['is_matched'])
        self.assertEqual(report['details']['unmapped_buses'], ['bus_17', 'bus_18'])
        self.assertEqual(report['stats']['diagram']['buses'], 0)
        self.assertTrue(any(d['type'] == 'unmapped' for d in report['discrepancies']))

    def test_verified_sld_apply_binds_exact_ids_and_preserves_topology(self):
        elements = [
            {'id': 'bus-west', 'type': 'bus', 'bus_number': 10, 'label': 'Bus 99', 'position': [1, 2]},
            {'id': 'bus-east', 'type': 'bus', 'bus_number': 20, 'label': 'Bus 10', 'position': [3, 4]},
            {
                'id': 'gen-west', 'type': 'generator', 'bus_number': 10,
                'connected_bus_number': 10, 'parentBusId': 'bus-west', 'label': 'G 99',
            },
            {
                'id': 'load-east', 'type': 'load', 'bus_number': 20,
                'connected_bus_number': 20, 'parentBusId': 'bus-east',
            },
            {
                'id': 'edge-west-east', 'type': 'line',
                'startElementId': 'bus-west', 'endElementId': 'bus-east',
                'ai_path': [[1, 2], [2, 3], [3, 4]],
            },
        ]
        excel_data = {
            'buses': {
                '10': {'type': 'Swing', 'is_slack': True, 'vm_pu': 1.02, 'va_deg': 0.0, 'pload_pu': 0.1, 'qload_pu': 0.02},
                '20': {'type': 'PQ', 'is_slack': False, 'vm_pu': 1.0, 'va_deg': -2.0, 'pload_pu': 0.3, 'qload_pu': 0.05},
            },
            'generators': {
                '10': {'pg_pu': 0.7, 'qg_pu': 0.12, 'voltage_setpoint': 1.02, 'is_slack': True},
            },
            'branches': {
                '10_20': {'from_bus': 10, 'to_bus': 20, 'r_pu': 0.012, 'x_pu': 0.08, 'b_pu': 0.004},
                '20_10': {'from_bus': 10, 'to_bus': 20, 'r_pu': 0.012, 'x_pu': 0.08, 'b_pu': 0.004},
            },
            'transformers': {},
        }
        original = deepcopy(elements)

        updated, summary = self.importer.apply_verified_sld_to_elements(elements, excel_data)

        self.assertEqual([e['id'] for e in updated], [e['id'] for e in original])
        self.assertEqual(updated[0]['isSlack'], True)
        self.assertEqual(updated[0]['bus_type'], 'Swing')
        self.assertEqual(updated[0]['vPu'], 1.02)
        self.assertEqual(updated[0]['thetaDeg'], 0.0)
        self.assertEqual(updated[2]['pPu'], 0.7)
        self.assertEqual(updated[3]['qPu'], 0.05)
        self.assertEqual(updated[4]['startElementId'], 'bus-west')
        self.assertEqual(updated[4]['endElementId'], 'bus-east')
        self.assertEqual(updated[4]['ai_path'], original[4]['ai_path'])
        self.assertEqual(updated[4]['parameterStatus'], 'VALID')
        self.assertEqual(updated[4]['rPu'], 0.012)
        self.assertEqual(updated[4]['xPu'], 0.08)
        self.assertEqual(updated[4]['bPu'], 0.004)
        self.assertFalse(summary['topology_mutated'])
        self.assertTrue(summary['power_flow_ready'])
        self.assertEqual(summary['applied_counts']['line'], 1)
        self.assertEqual(elements, original)

    def test_verified_sld_apply_binds_transformer_only_from_two_verified_bus_endpoints(self):
        elements = [
            {'id': 'bus-alpha', 'type': 'bus', 'bus_number': 3},
            {'id': 'bus-beta', 'type': 'bus', 'bus_number': 24},
            {'id': 'tx-exact-id', 'type': 'transformer', 'label': 'T 88-99'},
            {
                'id': 'lead-alpha-tx', 'type': 'line', 'startElementId': 'bus-alpha',
                'endElementId': 'tx-exact-id', 'electricalBranch': False,
            },
            {
                'id': 'lead-tx-beta', 'type': 'line', 'startElementId': 'tx-exact-id',
                'endElementId': 'bus-beta', 'electricalBranch': False,
            },
        ]
        excel_data = {
            'buses': {'3': {}, '24': {}},
            'generators': {},
            'branches': {},
            'transformers': {
                '3_24': {'from_bus': 3, 'to_bus': 24, 'r_pu': 0.0023, 'x_pu': 0.0839, 'b_pu': 0.0, 'tap': 1.03},
                '24_3': {'from_bus': 3, 'to_bus': 24, 'r_pu': 0.0023, 'x_pu': 0.0839, 'b_pu': 0.0, 'tap': 1.03},
            },
        }

        updated, summary = self.importer.apply_verified_sld_to_elements(elements, excel_data)

        transformer = next(e for e in updated if e['id'] == 'tx-exact-id')
        self.assertEqual(transformer['from_bus'], 3)
        self.assertEqual(transformer['to_bus'], 24)
        self.assertAlmostEqual(transformer['rPu'], 0.0023)
        self.assertAlmostEqual(transformer['xPu'], 0.0839)
        self.assertAlmostEqual(transformer['tapRatio'], 1.03)
        self.assertEqual(transformer['parameterStatus'], 'VALID')
        self.assertTrue(all(e['parameterStatus'] == 'NOT_APPLICABLE' for e in updated[3:]))
        self.assertEqual(summary['applied_counts']['transformer'], 1)

    def test_verified_sld_apply_never_infers_numbers_and_marks_missing_parameters(self):
        elements = [
            {'id': 'bus_17', 'type': 'bus', 'label': 'Bus 17'},
            {'id': 'bus_18', 'type': 'bus', 'label': 'Bus 18'},
            {
                'id': 'line_17_18', 'type': 'line', 'label': 'Line 17-18',
                'startElementId': 'bus_17', 'endElementId': 'bus_18',
                'rPu': 0.01, 'xPu': 0.05,
            },
        ]
        excel_data = {
            'buses': {'17': {}, '18': {}},
            'generators': {},
            'branches': {'17_18': {'from_bus': 17, 'to_bus': 18, 'r_pu': 0.02, 'x_pu': 0.09}},
            'transformers': {},
        }

        updated, summary = self.importer.apply_verified_sld_to_elements(elements, excel_data)

        self.assertEqual([e['id'] for e in updated], ['bus_17', 'bus_18', 'line_17_18'])
        self.assertNotIn('bus_number', updated[0])
        self.assertEqual(updated[2]['parameterStatus'], 'MISSING')
        self.assertIsNone(updated[2]['rPu'])
        self.assertIsNone(updated[2]['xPu'])
        self.assertIn('line_17_18', summary['missing_parameter_ids'])
        self.assertEqual(summary['applied_counts']['line'], 0)

    def test_verified_sld_apply_does_not_treat_excel_default_values_as_provided(self):
        elements = [
            {'id': 'bus-a', 'type': 'bus', 'bus_number': 1},
            {'id': 'bus-b', 'type': 'bus', 'bus_number': 2},
            {
                'id': 'edge-a-b', 'type': 'line', 'startElementId': 'bus-a',
                'endElementId': 'bus-b', 'rPu': 0.01, 'xPu': 0.05, 'bPu': 0.0,
            },
        ]
        excel_data = {
            'buses': {'1': {}, '2': {}},
            'generators': {},
            'branches': {
                '1_2': {
                    'from_bus': 1, 'to_bus': 2, 'r_pu': 0.02, 'x_pu': 0.08,
                    'b_pu': 0.0, 'provided_fields': ['r_pu', 'x_pu'],
                },
            },
            'transformers': {},
        }

        updated, summary = self.importer.apply_verified_sld_to_elements(elements, excel_data)

        line = updated[2]
        self.assertEqual(line['rPu'], 0.02)
        self.assertEqual(line['xPu'], 0.08)
        self.assertIsNone(line['bPu'])
        self.assertEqual(line['parameterStatus'], 'MISSING')
        self.assertEqual(line['parameterMissingFields'], ['bPu'])
        self.assertIn('edge-a-b', summary['missing_parameter_ids'])
        self.assertFalse(summary['power_flow_ready'])

    def test_verified_sld_excel_mismatch_blocks_normal_handoff_without_repair(self):
        elements = [
            {'id': 'node-1', 'type': 'bus', 'bus_number': 1, 'label': 'Bus 1'},
        ]
        excel_data = {
            'buses': {'2': {}},
            'generators': {},
            'branches': {},
            'transformers': {},
        }
        original = deepcopy(elements)

        updated, summary, mismatch = self.importer.apply_verified_sld_with_excel(
            elements,
            excel_data,
        )

        self.assertTrue(summary['blocked'])
        self.assertFalse(summary['topology_mutated'])
        self.assertFalse(mismatch['is_matched'])
        self.assertEqual(updated, original)
        self.assertEqual(elements, original)

if __name__ == '__main__':
    unittest.main()


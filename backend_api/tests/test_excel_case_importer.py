import unittest
import os
import sys

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


if __name__ == '__main__':
    unittest.main()


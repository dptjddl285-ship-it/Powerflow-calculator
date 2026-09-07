import unittest
import os
import sys

backend_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

from core.excel_case_importer import ExcelCaseImporter

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
        self.assertEqual(summary['applied_counts']['line'], 2)

        trans_el = next(e for e in updated if e['id'] == 'transformer_43')
        self.assertAlmostEqual(trans_el['tapRatio'], 1.03)
        self.assertAlmostEqual(trans_el['rPu'], 0.0023)
        self.assertAlmostEqual(trans_el['xPu'], 0.0839)
        self.assertIn('3-24', trans_el['label'])

        line1 = next(e for e in updated if e['id'] == 'L1')
        self.assertAlmostEqual(line1['tapRatio'], 1.03)
        self.assertAlmostEqual(line1['rPu'], 0.0023)
        self.assertAlmostEqual(line1['xPu'], 0.0839)
        self.assertIn('3-24', line1['label'])

        line2 = next(e for e in updated if e['id'] == 'L18')
        self.assertAlmostEqual(line2['tapRatio'], 1.03)
        self.assertAlmostEqual(line2['rPu'], 0.0023)
        self.assertAlmostEqual(line2['xPu'], 0.0839)
        self.assertIn('3-24', line2['label'])

if __name__ == '__main__':
    unittest.main()

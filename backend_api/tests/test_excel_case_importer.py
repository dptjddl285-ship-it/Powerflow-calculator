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
        bus13 = data['buses'][13]
        self.assertTrue(bus13['is_slack'])
        self.assertEqual(bus13['type'], 'Swing')
        self.assertAlmostEqual(bus13['pload_mw'], 265.0)
        self.assertAlmostEqual(bus13['pload_pu'], 2.65)

        # Bus 1 is PV
        bus1 = data['buses'][1]
        self.assertFalse(bus1['is_slack'])
        self.assertEqual(bus1['type'], 'PV')

        # Generator at Bus 13 is Slack
        gen13 = data['generators'][13]
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

if __name__ == '__main__':
    unittest.main()

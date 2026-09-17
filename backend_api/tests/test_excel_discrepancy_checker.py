# -*- coding: utf-8 -*-
import os
import sys
import unittest
from pathlib import Path

backend_dir = Path(__file__).resolve().parent.parent
if str(backend_dir) not in sys.path:
    sys.path.insert(0, str(backend_dir))

from core.excel_case_importer import ExcelCaseImporter
from agent.excel_discrepancy_agent import ExcelDiscrepancyAgent


class TestExcelDiscrepancyChecker(unittest.TestCase):
    def setUp(self):
        self.importer = ExcelCaseImporter()
        self.agent = ExcelDiscrepancyAgent()
        sample_path = backend_dir / "sample_cases" / "case24_psse.xlsx"
        if not sample_path.exists():
            sample_path = backend_dir / "sample_cases" / "ac_case25.xlsx"
        with open(sample_path, "rb") as f:
            self.excel_data = self.importer.parse_excel(f.read())

    def test_exact_match(self):
        """When all elements from excel exist on diagram, report is_matched == True."""
        elements = []
        for k, v in self.excel_data["buses"].items():
            elements.append({"id": f"bus_{k}", "type": "bus", "bus_number": int(k), "label": f"{k}"})

        for k, v in self.excel_data["generators"].items():
            elements.append({"id": f"gen_{k}", "type": "generator", "parentBusId": f"bus_{k}", "bus_number": int(k)})

        for k, v in self.excel_data["buses"].items():
            if float(v.get("pload_pu", 0) or v.get("pload_mw", 0)) > 0:
                elements.append({"id": f"load_{k}", "type": "load", "parentBusId": f"bus_{k}", "bus_number": int(k)})

        for k, br in self.excel_data["branches"].items():
            fb, tb = int(br["from_bus"]), int(br["to_bus"])
            elements.append({"id": f"line_{fb}_{tb}", "type": "line", "startElementId": f"bus_{fb}", "endElementId": f"bus_{tb}"})

        for k, tr in self.excel_data.get("transformers", {}).items():
            fb, tb = int(tr["from_bus"]), int(tr["to_bus"])
            elements.append({"id": f"trans_{fb}_{tb}", "type": "transformer", "startElementId": f"bus_{fb}", "endElementId": f"bus_{tb}"})

        report = self.importer.compare_elements_with_excel(elements, self.excel_data)
        self.assertTrue(report["is_matched"])
        self.assertEqual(len(report["discrepancies"]), 0)
        self.assertIn("일치", report["summary"])

    def test_missing_bus_and_branch_discrepancy(self):
        """When Bus 14 and branches connected to it are omitted, report catches them."""
        elements = []
        for k, v in self.excel_data["buses"].items():
            if int(k) == 14:
                continue  # Skip bus 14
            elements.append({"id": f"bus_{k}", "type": "bus", "bus_number": int(k), "label": f"{k}"})

        report = self.importer.compare_elements_with_excel(elements, self.excel_data)
        self.assertFalse(report["is_matched"])
        self.assertIn(14, report["details"]["missing_buses"])
        self.assertGreater(len(report["discrepancies"]), 0)

        # Diagnose via agent
        diagnosis = self.agent.diagnose(elements, self.excel_data, report)
        self.assertEqual(diagnosis["status"], "mismatch")
        self.assertIn("advice_ko", diagnosis)
        self.assertTrue(len(diagnosis.get("headline", "")) > 0)
        self.assertGreater(len(diagnosis.get("suggested_actions", [])), 0)


    def test_synchronous_condenser_load_equivalence(self):
        """Bus 14 having a load symbol in the diagram satisfies the synchronous condenser requirement."""
        elements = []
        for k in self.excel_data["buses"].keys():
            elements.append({"id": f"bus_{k}", "type": "bus", "bus_number": int(k), "label": f"{k}"})
        # For bus 14, provide a load instead of an explicit generator
        elements.append({"id": "load_14", "type": "load", "parentBusId": "bus_14", "bus_number": 14})

        # Generator for all other buses
        for k in self.excel_data["generators"].keys():
            if int(k) != 14:
                elements.append({"id": f"gen_{k}", "type": "generator", "parentBusId": f"bus_{k}", "bus_number": int(k)})

        report = self.importer.compare_elements_with_excel(elements, self.excel_data)
        # Bus 14 should NOT be in missing_generators!
        self.assertNotIn(14, report["details"]["missing_generators"])

    def test_transformer_multibus_connections(self):
        """Transformers connecting 9, 10, 11, 12 should resolve 9-12 and 10-11."""
        elements = [
            {"id": "bus_9", "type": "bus", "bus_number": 9, "label": "9"},
            {"id": "bus_10", "type": "bus", "bus_number": 10, "label": "10"},
            {"id": "bus_11", "type": "bus", "bus_number": 11, "label": "11"},
            {"id": "bus_12", "type": "bus", "bus_number": 12, "label": "12"},
            {"id": "trans_1", "type": "transformer"},
            {"id": "l1", "type": "line", "connected_to": ["trans_1", "bus_9"]},
            {"id": "l2", "type": "line", "connected_to": ["trans_1", "bus_10"]},
            {"id": "l3", "type": "line", "connected_to": ["trans_1", "bus_11"]},
            {"id": "l4", "type": "line", "connected_to": ["trans_1", "bus_12"]},
        ]
        report = self.importer.compare_elements_with_excel(elements, self.excel_data)
        missing = report["details"]["missing_branches"]
        self.assertNotIn([9, 12], missing)
        self.assertNotIn([10, 11], missing)


if __name__ == "__main__":
    unittest.main()

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


if __name__ == "__main__":
    unittest.main()

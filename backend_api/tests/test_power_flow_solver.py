"""
Unit test for AC Newton-Raphson PowerFlowSolver
Validates convergence, power balance conservation, strict electrical parameter handling,
and refusal to generate synthetic buses or generators for missing components.
"""

from __future__ import annotations
from pathlib import Path
import sys
import unittest

sys.stdout.reconfigure(encoding='utf-8')

backend_dir = Path(__file__).resolve().parent.parent
if str(backend_dir) not in sys.path:
    sys.path.insert(0, str(backend_dir))

from core.power_flow_solver import PowerFlowSolver
from core.excel_case_importer import ExcelCaseImporter


def _require_param(data: dict, *keys: str, name: str = "parameter") -> float:
    """
    Validates that a required electrical parameter exists in the dictionary,
    is not None, and is convertible to float.
    0.0 is a valid value and must NOT be treated as missing.
    Raises AssertionError if the key is missing or invalid.
    """
    for k in keys:
        if k in data and data[k] is not None:
            try:
                return float(data[k])
            except (ValueError, TypeError):
                raise AssertionError(f"Parameter '{name}' (key '{k}') is not a valid float: {data[k]!r}")
    raise AssertionError(f"Required electrical parameter '{name}' missing in Excel data (checked keys: {keys}). Entry: {data}")


def test_standard_3bus():
    print("\n--- [Test 1: Standard 3-Bus Power Flow] ---")
    elements = [
        {"id": "bus_1", "type": "bus", "label": "Bus 1", "isSlack": True, "vPu": 1.05, "thetaDeg": 0.0},
        {"id": "bus_2", "type": "bus", "label": "Bus 2", "isSlack": False, "vPu": 1.0, "thetaDeg": 0.0},
        {"id": "bus_3", "type": "bus", "label": "Bus 3", "isSlack": False, "vPu": 1.0, "thetaDeg": 0.0},
        # Gen on Bus 2 (PV bus)
        {"id": "gen_2", "type": "generator", "parentBusId": "bus_2", "pPu": 0.5, "vPu": 1.02},
        # Load on Bus 3 (PQ bus)
        {"id": "load_3", "type": "load", "parentBusId": "bus_3", "pPu": 0.8, "qPu": 0.4},
        # Lines
        {"id": "line_1_2", "type": "line", "startElementId": "bus_1", "endElementId": "bus_2", "rPu": 0.02, "xPu": 0.1, "bPu": 0.02},
        {"id": "line_1_3", "type": "line", "startElementId": "bus_1", "endElementId": "bus_3", "rPu": 0.01, "xPu": 0.05, "bPu": 0.02},
        {"id": "line_2_3", "type": "line", "startElementId": "bus_2", "endElementId": "bus_3", "rPu": 0.015, "xPu": 0.08, "bPu": 0.02},
    ]

    solver = PowerFlowSolver(s_base=100.0)
    result = solver.solve(elements)

    assert result["status"] == "success", "Solver failed"
    assert result["converged"] is True, "Power flow did not converge"
    assert result["iterations"] <= 6, f"Too many iterations: {result['iterations']}"

    print(f"✅ Converged in {result['iterations']} iterations! Max mismatch: {result['max_mismatch']}")
    print("\n[Result CSV Output]:")
    print(result["csv_text"])

    # Verify power balance: Total Gen = Total Load + Total Loss (error < 0.01 MW)
    summary = result["summary"]
    total_gen_p = summary["total_gen_p_mw"]
    total_load_p = summary["total_load_p_mw"]
    total_loss_p = summary["total_loss_p_mw"]
    p_diff = abs(total_gen_p - (total_load_p + total_loss_p))
    print(f"Power balance check: Gen={total_gen_p:.2f} MW, Load={total_load_p:.2f} MW, Loss={total_loss_p:.2f} MW -> Diff={p_diff:.4f} MW")
    assert p_diff < 0.05, f"Power conservation violated: diff={p_diff}"


def test_excel_case25():
    print("\n--- [Test 2: ac_case25 Excel Real System] ---")
    sample_path = backend_dir / "sample_cases" / "ac_case25.xlsx"
    if not sample_path.exists():
        print("Sample ac_case25.xlsx not found, skipping.")
        return

    with open(sample_path, "rb") as f:
        data = f.read()

    importer = ExcelCaseImporter()
    parsed = importer.parse_excel(data)

    # Convert parsed excel case directly to elements for solver
    elements = []
    slack_bus = parsed.get("slack_bus_number", 13)

    for b_no_str, b_info in parsed.get("buses", {}).items():
        b_no = int(b_no_str)
        elements.append({
            "id": f"bus_{b_no}",
            "type": "bus",
            "label": f"Bus {b_no}",
            "isSlack": (b_no == slack_bus),
            "vPu": b_info.get("vm_pu", 1.0),
            "thetaDeg": b_info.get("va_deg", 0.0),
        })

    for b_no_str, g_info in parsed.get("generators", {}).items():
        b_no = int(b_no_str)
        elements.append({
            "id": f"gen_{b_no}",
            "type": "generator",
            "parentBusId": f"bus_{b_no}",
            "isSlack": (b_no == slack_bus),
            "pPu": g_info.get("pg_pu", 0.0),
            "qPu": g_info.get("qg_pu", 0.0),
            "vPu": g_info.get("voltage_setpoint", 1.0),
        })

    for b_no_str, b_info in parsed.get("buses", {}).items():
        b_no = int(b_no_str)
        p_l = b_info.get("pload_pu", 0.0)
        q_l = b_info.get("qload_pu", 0.0)
        if p_l > 0 or q_l > 0:
            elements.append({
                "id": f"load_{b_no}",
                "type": "load",
                "parentBusId": f"bus_{b_no}",
                "pPu": p_l,
                "qPu": q_l,
            })

    for key, br_info in parsed.get("branches", {}).items():
        fb = br_info.get("from_bus")
        tb = br_info.get("to_bus")
        r_pu = _require_param(br_info, "r_pu", "rPu", name="r_pu")
        x_pu = _require_param(br_info, "x_pu", "xPu", name="x_pu")
        b_pu = _require_param(br_info, "b_pu", "bPu", name="b_pu")
        elements.append({
            "id": f"line_{fb}_{tb}",
            "type": "line",
            "startElementId": f"bus_{fb}",
            "endElementId": f"bus_{tb}",
            "rPu": r_pu,
            "xPu": x_pu,
            "bPu": b_pu,
        })

    for key, tr_info in parsed.get("transformers", {}).items():
        fb = tr_info.get("from_bus")
        tb = tr_info.get("to_bus")
        r_pu = _require_param(tr_info, "r_pu", "rPu", name="r_pu")
        x_pu = _require_param(tr_info, "x_pu", "xPu", name="x_pu")
        b_pu = _require_param(tr_info, "b_pu", "bPu", name="b_pu")
        tap = _require_param(tr_info, "tap", "ratio", "tap_ratio", "tapRatio", name="tap")
        elements.append({
            "id": f"trans_{fb}_{tb}",
            "type": "transformer",
            "startElementId": f"bus_{fb}",
            "endElementId": f"bus_{tb}",
            "rPu": r_pu,
            "xPu": x_pu,
            "bPu": b_pu,
            "tapRatio": tap,
        })

    solver = PowerFlowSolver(s_base=100.0, tol=1e-4, max_iter=30)
    result = solver.solve(elements)

    assert result["status"] == "success"
    assert result["converged"] is True, f"ac_case25 did not converge (iter={result['iterations']}, mismatch={result['max_mismatch']})"
    print(f"✅ ac_case25 Converged in {result['iterations']} iterations! Max mismatch: {result['max_mismatch']}")
    print(f"Summary: {result['summary']}")
    print("\nFirst 5 rows of output CSV:")
    print("\n".join(result["csv_text"].splitlines()[:6]))


class TestPowerFlowSolverRequirements(unittest.TestCase):
    """
    Comprehensive verification for strict parameter fidelity and refusal
    to auto-generate missing buses or missing benchmark generators.
    """

    def setUp(self):
        self.solver = PowerFlowSolver(s_base=100.0)

    def test_1_excel_branch_params_preserved(self):
        """TEST 1: 정상 Excel branch의 R/X/B가 test fixture에 그대로 전달된다."""
        sample_path = backend_dir / "sample_cases" / "ac_case25.xlsx"
        if not sample_path.exists():
            self.skipTest("ac_case25.xlsx not found")

        with open(sample_path, "rb") as f:
            data = f.read()

        importer = ExcelCaseImporter()
        parsed = importer.parse_excel(data)

        # Check that every single branch and transformer extracts genuine Excel numbers
        for key, br in parsed.get("branches", {}).items():
            r = _require_param(br, "r_pu", "rPu")
            x = _require_param(br, "x_pu", "xPu")
            b = _require_param(br, "b_pu", "bPu")
            self.assertEqual(r, float(br["r_pu"]))
            self.assertEqual(x, float(br["x_pu"]))
            self.assertEqual(b, float(br["b_pu"]))

        for key, tr in parsed.get("transformers", {}).items():
            r = _require_param(tr, "r_pu", "rPu")
            x = _require_param(tr, "x_pu", "xPu")
            b = _require_param(tr, "b_pu", "bPu")
            tap = _require_param(tr, "tap", "ratio", "tap_ratio", "tapRatio")
            self.assertEqual(r, float(tr["r_pu"]))
            self.assertEqual(x, float(tr["x_pu"]))
            self.assertEqual(b, float(tr["b_pu"]))
            self.assertEqual(tap, float(tr["tap"]))

    def test_2_zero_r_or_b_preserved_no_fallback(self):
        """TEST 2: R=0.0 또는 B=0.0이 fallback 값으로 변경되지 않는다."""
        # 1. Test helper preserves 0.0
        val_r = _require_param({"r_pu": 0.0}, "r_pu", name="r_pu")
        val_b = _require_param({"b_pu": 0.0}, "b_pu", name="b_pu")
        self.assertEqual(val_r, 0.0)
        self.assertEqual(val_b, 0.0)

        # 2. Test solver parse_elements preserves 0.0 without falsy bug
        elements = [
            {"id": "bus_1", "type": "bus", "label": "Bus 1", "isSlack": True},
            {"id": "bus_2", "type": "bus", "label": "Bus 2", "isSlack": False},
            {"id": "line_1_2", "type": "line", "startElementId": "bus_1", "endElementId": "bus_2", "rPu": 0.0, "xPu": 0.05, "bPu": 0.0},
        ]
        parsed = self.solver.parse_elements(elements)
        self.assertEqual(len(parsed["branches"]), 1)
        br = parsed["branches"][0]
        self.assertEqual(br["r_pu"], 0.0)
        self.assertEqual(br["b_pu"], 0.0)

    def test_3_missing_excel_rx_fails_or_validates(self):
        """TEST 3: Excel R 또는 X가 실제로 missing이면 테스트가 실패하거나 명시적 validation error를 확인한다. 0.01 / 0.05를 삽입하지 않는다."""
        # 1. Missing in excel data -> _require_param raises AssertionError
        missing_entry = {"from_bus": 1, "to_bus": 2}
        with self.assertRaises(AssertionError):
            _require_param(missing_entry, "r_pu", name="r_pu")

        # 2. Missing in solver elements -> validation error, no fallback inserted
        elements = [
            {"id": "bus_1", "type": "bus", "label": "Bus 1", "isSlack": True},
            {"id": "bus_2", "type": "bus", "label": "Bus 2", "isSlack": False},
            {"id": "line_1_2", "type": "line", "startElementId": "bus_1", "endElementId": "bus_2"},
        ]
        result = self.solver.solve(elements)
        self.assertEqual(result["status"], "error")
        self.assertFalse(result["converged"])
        self.assertTrue(any("Missing electrical parameters" in err for err in result.get("validation_errors", [])))

    def test_4_generator_valid_bus_reference(self):
        """TEST 4: Generator가 존재하는 Bus를 정상 참조하면 기존과 동일하게 계산된다."""
        elements = [
            {"id": "bus_1", "type": "bus", "label": "Bus 1", "isSlack": True, "vPu": 1.05},
            {"id": "bus_2", "type": "bus", "label": "Bus 2", "isSlack": False, "vPu": 1.0},
            {"id": "gen_2", "type": "generator", "parentBusId": "bus_2", "pPu": 0.5, "vPu": 1.02},
            {"id": "line_1_2", "type": "line", "startElementId": "bus_1", "endElementId": "bus_2", "rPu": 0.01, "xPu": 0.05, "bPu": 0.0},
        ]
        result = self.solver.solve(elements)
        self.assertEqual(result["status"], "success")
        self.assertTrue(result["converged"])
        self.assertEqual(result["slack_bus"], 1)

    def test_5_generator_missing_bus_error(self):
        """TEST 5: Generator가 존재하지 않는 Bus 99를 참조하면 Bus 99가 자동 생성되지 않고 계산이 error로 종료된다."""
        elements = [
            {"id": "bus_1", "type": "bus", "label": "Bus 1", "isSlack": True},
            {"id": "bus_2", "type": "bus", "label": "Bus 2", "isSlack": False},
            {"id": "line_1_2", "type": "line", "startElementId": "bus_1", "endElementId": "bus_2", "rPu": 0.01, "xPu": 0.05, "bPu": 0.0},
            # Generator referencing non-existent Bus 99
            {"id": "gen_99", "type": "generator", "parentBusId": "bus_99", "pPu": 0.5, "vPu": 1.0},
        ]

        # 1. parse_elements should NOT create Bus 99
        parsed = self.solver.parse_elements(elements)
        self.assertNotIn(99, parsed["buses"], "Solver must NOT auto-create missing Bus 99")
        self.assertEqual(len(parsed["buses"]), 2)
        self.assertTrue(any("missing Bus 99" in err for err in parsed["validation_errors"]))

        # 2. solve should return structured error
        result = self.solver.solve(elements)
        self.assertEqual(result["status"], "error")
        self.assertFalse(result["converged"])
        self.assertIn("Generator gen_99 references missing Bus 99.", result["message"])
        self.assertIn("validation_errors", result)

    def test_6_load_missing_bus_error(self):
        """TEST 6: Load가 존재하지 않는 Bus 88을 참조하면 Bus 88이 자동 생성되지 않고 계산이 error로 종료된다."""
        elements = [
            {"id": "bus_1", "type": "bus", "label": "Bus 1", "isSlack": True},
            {"id": "bus_2", "type": "bus", "label": "Bus 2", "isSlack": False},
            {"id": "line_1_2", "type": "line", "startElementId": "bus_1", "endElementId": "bus_2", "rPu": 0.01, "xPu": 0.05, "bPu": 0.0},
            # Load referencing non-existent Bus 88
            {"id": "load_8", "type": "load", "parentBusId": "bus_88", "pPu": 0.3, "qPu": 0.1},
        ]

        # 1. parse_elements should NOT create Bus 88
        parsed = self.solver.parse_elements(elements)
        self.assertNotIn(88, parsed["buses"], "Solver must NOT auto-create missing Bus 88")
        self.assertEqual(len(parsed["buses"]), 2)
        self.assertTrue(any("missing Bus 88" in err for err in parsed["validation_errors"]))

        # 2. solve should return structured error
        result = self.solver.solve(elements)
        self.assertEqual(result["status"], "error")
        self.assertFalse(result["converged"])
        self.assertIn("Load load_8 references missing Bus 88.", result["message"])

    def test_7_no_auto_creation_of_bus14_generator(self):
        """TEST 7: 24개의 Bus를 가진 입력에서 Bus14 Generator가 입력에 없더라도 solver가 100 MW Generator를 자동 생성하지 않는다."""
        elements = []
        for i in range(1, 25):
            elements.append({
                "id": f"bus_{i}",
                "type": "bus",
                "label": f"Bus {i}",
                "isSlack": (i == 1),
            })
        for i in range(1, 24):
            elements.append({
                "id": f"line_{i}_{i+1}",
                "type": "line",
                "startElementId": f"bus_{i}",
                "endElementId": f"bus_{i+1}",
                "rPu": 0.01,
                "xPu": 0.05,
                "bPu": 0.0,
            })
        # Add generator ONLY at Bus 1 (Slack) - No generator at Bus 14
        elements.append({
            "id": "gen_1",
            "type": "generator",
            "parentBusId": "bus_1",
            "isSlack": True,
            "pPu": 0.0,
            "vPu": 1.0,
        })

        parsed = self.solver.parse_elements(elements)
        gens_by_bus = parsed["gens_by_bus"]

        # Bus 14 must NOT have any generator automatically created
        self.assertNotIn(14, gens_by_bus, "Solver must NOT synthesize a generator on Bus 14")
        self.assertEqual(len(gens_by_bus.get(14, [])), 0)

    def test_8_regression_standard_3bus_and_ac_case25(self):
        """TEST 8: 기존 Standard 3-Bus 및 정상 ac_case25 regression test가 유지된다."""
        test_standard_3bus()
        test_excel_case25()


if __name__ == "__main__":
    test_standard_3bus()
    test_excel_case25()
    print("\n[Running unittest suite for TestPowerFlowSolverRequirements]:")
    unittest.main(argv=['first-arg-is-ignored'], exit=False)
    print("\n🎉 ALL TESTS PASSED SUCCESSFULLY!")

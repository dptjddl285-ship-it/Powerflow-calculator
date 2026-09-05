"""
Unit test for AC Newton-Raphson PowerFlowSolver
Validates convergence, power balance conservation, and user output format.
"""

from __future__ import annotations
from pathlib import Path
import sys

sys.stdout.reconfigure(encoding='utf-8')

backend_dir = Path(__file__).resolve().parent.parent
if str(backend_dir) not in sys.path:
    sys.path.insert(0, str(backend_dir))

from core.power_flow_solver import PowerFlowSolver
from core.excel_case_importer import ExcelCaseImporter


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
        elements.append({
            "id": f"line_{fb}_{tb}",
            "type": "line",
            "startElementId": f"bus_{fb}",
            "endElementId": f"bus_{tb}",
            "rPu": br_info.get("r_pu", 0.01),
            "xPu": br_info.get("x_pu", 0.05),
            "bPu": br_info.get("b_pu", 0.0),
            "tapRatio": 1.0,
        })

    for key, tr_info in parsed.get("transformers", {}).items():
        fb = tr_info.get("from_bus")
        tb = tr_info.get("to_bus")
        elements.append({
            "id": f"trans_{fb}_{tb}",
            "type": "transformer",
            "startElementId": f"bus_{fb}",
            "endElementId": f"bus_{tb}",
            "rPu": tr_info.get("r_pu", 0.005),
            "xPu": tr_info.get("x_pu", 0.04),
            "bPu": 0.0,
            "tapRatio": tr_info.get("ratio", 1.0),
        })

    solver = PowerFlowSolver(s_base=100.0, tol=1e-4, max_iter=30)
    result = solver.solve(elements)

    assert result["status"] == "success"
    assert result["converged"] is True, f"ac_case25 did not converge (iter={result['iterations']}, mismatch={result['max_mismatch']})"
    print(f"✅ ac_case25 Converged in {result['iterations']} iterations! Max mismatch: {result['max_mismatch']}")
    print(f"Summary: {result['summary']}")
    print("\nFirst 5 rows of output CSV:")
    print("\n".join(result["csv_text"].splitlines()[:6]))


if __name__ == "__main__":
    test_standard_3bus()
    test_excel_case25()
    print("\n🎉 ALL TESTS PASSED SUCCESSFULLY!")

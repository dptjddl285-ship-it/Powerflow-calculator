import os
import sys

# Ensure UTF-8 output encoding on Windows console
if sys.platform.startswith('win'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
if CURRENT_DIR not in sys.path:
    sys.path.insert(0, CURRENT_DIR)

from core.pandapower_engine import build_net_from_elements, run_power_flow_simulation, render_single_line_diagram
from fastapi.testclient import TestClient
from main_server import app

def test_custom_elements_power_flow():
    print("=" * 60)
    print("🧪 Test 1: Custom Flutter Canvas Elements Power Flow")
    print("=" * 60)
    
    # 3-Bus Sample System (Slack Gen at B1, Load at B2, Line B1-B2, Line B2-B3, Gen at B3)
    sample_elements = [
        {'id': 'B1', 'type': 'bus', 'isSlack': True, 'vPu': 1.05, 'thetaDeg': 0.0},
        {'id': 'B2', 'type': 'bus', 'isSlack': False, 'vPu': 1.0, 'thetaDeg': 0.0},
        {'id': 'B3', 'type': 'bus', 'isSlack': False, 'vPu': 1.0, 'thetaDeg': 0.0},
        {'id': 'G1', 'type': 'generator', 'parentBusId': 'B1', 'isSlack': True, 'vPu': 1.05},
        {'id': 'L1', 'type': 'line', 'startElementId': 'B1', 'endElementId': 'B2', 'rPu': 0.02, 'xPu': 0.08},
        {'id': 'L2', 'type': 'line', 'startElementId': 'B2', 'endElementId': 'B3', 'rPu': 0.03, 'xPu': 0.12},
        {'id': 'LD1', 'type': 'load', 'parentBusId': 'B2', 'pMw': 40.0, 'qMvar': 15.0},
        {'id': 'LD2', 'type': 'load', 'parentBusId': 'B3', 'pMw': 25.0, 'qMvar': 10.0},
        {'id': 'G2', 'type': 'generator', 'parentBusId': 'B3', 'pMw': 20.0, 'vPu': 1.02},
    ]

    result = run_power_flow_simulation(elements=sample_elements, return_plot=True)
    print(f"Status: {result.get('status')}")
    print(f"Message: {result.get('message')}")
    assert result.get('status') == 'success', f"Expected success but got {result}"
    
    summary = result.get('summary', {})
    print(f"Converged: {summary.get('converged')}")
    print(f"Total Gen: {summary.get('total_generation_mw')} MW | Total Load: {summary.get('total_load_mw')} MW | Losses: {summary.get('total_losses_mw')} MW")
    print(f"Plot Base64 Length: {len(result.get('plot_image_base64', ''))} characters")
    
    assert summary.get('converged') is True
    assert len(result.get('bus_results', [])) == 3
    assert len(result.get('line_results', [])) == 2
    assert result.get('plot_image_base64') is not None
    print("✅ Test 1 Passed!\n")

def test_ieee_standard_cases():
    print("=" * 60)
    print("🧪 Test 2: IEEE Standard Cases (14-Bus & 30-Bus)")
    print("=" * 60)
    
    for case in ['case14', 'case30']:
        result = run_power_flow_simulation(case_name=case, return_plot=True)
        print(f"[{case.upper()}] Status: {result.get('status')}, Converged: {result.get('summary', {}).get('converged')}")
        assert result.get('status') == 'success'
        assert result.get('summary', {}).get('converged') is True
        assert result.get('plot_image_base64') is not None
        
    print("✅ Test 2 Passed!\n")

def test_fastapi_endpoints():
    print("=" * 60)
    print("🧪 Test 3: FastAPI Endpoints (TestClient)")
    print("=" * 60)
    
    client = TestClient(app)
    
    # 1. GET /ieee_cases
    r = client.get("/ieee_cases")
    assert r.status_code == 200
    cases = r.json().get('cases', [])
    print(f"1. /ieee_cases returned {len(cases)} cases: {[c['id'] for c in cases]}")
    assert len(cases) >= 5
    
    # 2. POST /run_ieee_case
    r = client.post("/run_ieee_case", json={"case": "case14"})
    assert r.status_code == 200
    data = r.json()
    assert data.get('status') == 'success'
    print(f"2. /run_ieee_case (case14) success: Total Gen = {data['summary']['total_generation_mw']} MW")
    
    # 3. POST /run_simulation with custom elements
    sample_elements = [
        {'id': 'B1', 'type': 'bus', 'isSlack': True, 'vPu': 1.0},
        {'id': 'B2', 'type': 'bus', 'isSlack': False, 'vPu': 1.0},
        {'id': 'L1', 'type': 'line', 'startElementId': 'B1', 'endElementId': 'B2', 'rPu': 0.01, 'xPu': 0.05},
        {'id': 'LD1', 'type': 'load', 'parentBusId': 'B2', 'pMw': 10.0, 'qMvar': 5.0}
    ]
    r = client.post("/run_simulation", json={"elements": sample_elements})
    assert r.status_code == 200
    data = r.json()
    assert data.get('status') == 'success'
    print(f"3. /run_simulation success: Message = '{data['message']}', Y-Bus Size = {data.get('y_bus_size')}")
    
    # 4. GET /render_ieee_image/case14
    r = client.get("/render_ieee_image/case14")
    assert r.status_code == 200
    assert r.headers['content-type'] == 'image/png'
    print(f"4. /render_ieee_image/case14 returned PNG image ({len(r.content)} bytes)")
    
    print("✅ Test 3 Passed!\n")

if __name__ == "__main__":
    test_custom_elements_power_flow()
    test_ieee_standard_cases()
    test_fastapi_endpoints()
    print("=" * 60)
    print("🎉 ALL TESTS COMPLETED SUCCESSFULLY! 🎉")
    print("=" * 60)

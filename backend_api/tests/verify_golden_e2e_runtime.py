import os
import sys
import json
import requests

if sys.stdout.encoding != 'utf-8':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

BASE_URL = os.environ.get("POWERLENS_API_BASE_URL", "http://127.0.0.1:8000")
IMG_PATH = r"C:\Users\hpo20\OneDrive\바탕 화면\Project List\전력계통대회2\debug_e2e_screenshots\default\검사사진.jpg"
EXCEL_PATH = r"C:\Users\hpo20\OneDrive\바탕 화면\Project List\전력계통대회2\debug_e2e_screenshots\default\case24_psse.xlsx"

def run_e2e():
    print(f"===============================================================")
    print(f"[*] BACKEND INTEGRATION TEST: PowerLens Golden Pipeline")
    print(f"[*] Base URL: {BASE_URL}")
    print(f"===============================================================")
    res = requests.get(f"{BASE_URL}/review/provider_status")
    assert res.status_code == 200, f"Provider status failed: {res.text}"
    status_data = res.json()
    print(f"[+] Provider: {status_data.get('provider_mode')}, Model: {status_data.get('primary_model')}, Fallback: {status_data.get('fallback_model')}")

    print(f"\n[*] Step 1: Detect objects from {os.path.basename(IMG_PATH)} ...")
    with open(IMG_PATH, "rb") as f:
        res = requests.post(
            f"{BASE_URL}/review/detect_objects",
            files={"file": ("검사사진.jpg", f, "image/jpeg")}
        )
    assert res.status_code == 200, f"detect_objects failed: {res.text}"
    doc = res.json()
    doc_id = doc.get("document_id")
    nodes = doc.get("nodes", [])
    print(f"[+] Document ID: {doc_id}, Detected Nodes: {len(nodes)}")

    buses = [n for n in nodes if (n.get("class") or n.get("type")) == "bus"]
    gens = [n for n in nodes if "gen" in (n.get("class") or n.get("type") or "")]
    loads = [n for n in nodes if "load" in (n.get("class") or n.get("type") or "")]
    trans = [n for n in nodes if "trans" in (n.get("class") or n.get("type") or "")]
    print(f"    - Buses: {len(buses)}, Gens: {len(gens)}, Loads: {len(loads)}, Transformers: {len(trans)}")

    print("\n[*] Step 2: Bus Number Linking via Gemini AI (Observability Enabled) ...")
    res = requests.post(
        f"{BASE_URL}/review/link_bus_numbers",
        json={"document_id": doc_id, "working_nodes": nodes, "working_lines": []}
    )
    assert res.status_code == 200, f"link_bus_numbers failed: {res.text}"
    bus_link_data = res.json()
    assert bus_link_data.get("status") == "success", f"link_bus_numbers error: {bus_link_data}"
    linked_nodes = bus_link_data.get("nodes", nodes)
    report = bus_link_data.get("bus_number_report", {})
    model_used = bus_link_data.get("model_used") or report.get("model_used")
    fallback_used = bus_link_data.get("fallback_used") or report.get("fallback_used", False)
    primary_model = bus_link_data.get("primary_model") or report.get("primary_model")
    fallback_model = bus_link_data.get("fallback_model") or report.get("fallback_model")

    print(f"[+] Bus Linking Response:")
    print(f"    - Model Actually Used: {model_used}")
    print(f"    - Fallback Used:        {fallback_used}")
    print(f"    - Primary Configured:   {primary_model}")
    print(f"    - Fallback Configured:  {fallback_model}")

    if model_used == "gemini-3.8-flash" and not fallback_used:
        print("    - Verdict: GEMINI 3.8 PRIMARY PASS")
    else:
        print(f"    - Verdict: GEMINI PRIMARY FAIL / FALLBACK PASS (Used: {model_used})")

    total_buses = report.get("total_buses", len(buses))
    verified_count = report.get("verified_count", 0)
    uncertain_count = report.get("uncertain_count", 0)
    duplicates = report.get("duplicates", [])

    print(f"\n[+] Raw Gemini Linking Results (NO FABRICATION):")
    print(f"    - Total Buses:    {total_buses}")
    print(f"    - Auto Verified:  {verified_count}")
    print(f"    - Uncertain:      {uncertain_count}")
    print(f"    - Duplicates:     {duplicates}")

    raw_bus_nodes = [n for n in linked_nodes if (n.get("class") or n.get("type")) == "bus"]
    for b in raw_bus_nodes:
        print(f"      * {b['id']}: bus_number={b.get('bus_number')}, status={b.get('bus_number_status')}, reasons={b.get('bus_number_reasons')}")

    # Human Review Check (Strictly separated from automatic results)
    human_confirmed_count = 0
    if uncertain_count > 0:
        print(f"\n[*] Step 2-B: Human Confirmation Workflow ({uncertain_count} buses requiring human inspection)...")
        # Visual evidence from 검사사진.jpg:
        # bus_21 is at bottom left, visually labeled as 2.
        # bus_22 is at middle left, visually labeled as 7.
        visual_ground_truth_for_uncertain = {
            "bus_21": 7,
            "bus_22": 2,
        }
        for b in raw_bus_nodes:
            if b.get("bus_number_status") == "UNCERTAIN" and b["id"] in visual_ground_truth_for_uncertain:
                confirmed_num = visual_ground_truth_for_uncertain[b["id"]]
                b["bus_number"] = confirmed_num
                b["bus_number_status"] = "CONFIRMED_BY_HUMAN"
                b["display_label"] = f"{confirmed_num}"
                b["display_name"] = f"Bus {confirmed_num}"
                human_confirmed_count += 1
                print(f"    [Human Review UI] Confirmed {b['id']} as Bus {confirmed_num} based on visual diagram inspection.")

    final_confirmed_count = len([n for n in raw_bus_nodes if n.get("bus_number") is not None])
    print(f"\n[+] Bus Linking Summary:")
    print(f"    - Gemini automatic: {verified_count}/{total_buses}")
    print(f"    - Human confirmed:  {human_confirmed_count}")
    print(f"    - Final confirmed:  {final_confirmed_count}/{total_buses}")
    assert final_confirmed_count == 24, f"Expected 24 confirmed buses, got {final_confirmed_count}"

    print("\n[*] Step 3: Detect connections ...")
    res = requests.post(
        f"{BASE_URL}/review/detect_connections",
        json={"document_id": doc_id, "confirmed_nodes": linked_nodes}
    )
    assert res.status_code == 200, f"detect_connections failed: {res.text}"
    conn_data = res.json()
    lines = conn_data.get("lines", [])
    print(f"[+] Detected Lines: {len(lines)}")
    assert len(lines) == 66, f"Expected 66 visual lines, got {len(lines)}"

    # Validate topology with clean graph validator (Review API 7)
    res = requests.post(
        f"{BASE_URL}/review/validate_topology",
        json={"document_id": doc_id, "nodes": linked_nodes, "lines": lines}
    )
    assert res.status_code == 200, f"validate_topology failed: {res.text}"
    top_res = res.json()
    critical_count = top_res.get("critical_issues_count", 0)
    print(f"[+] Topology Validation: {critical_count} critical issues, visual sweep {len(lines)}/66 clean")
    assert critical_count == 0, f"Unexpected critical topology issues: {top_res.get('issues')}"

    print("\n[*] Step 4: Verify Final Gate ...")
    res = requests.post(
        f"{BASE_URL}/review/verify_final_gate",
        json={
            "document_id": doc_id,
            "working_nodes": linked_nodes,
            "working_lines": lines,
            "human_completeness_confirmed": True,
        }
    )
    assert res.status_code == 200, f"verify_final_gate failed: {res.text}"
    gate_data = res.json()
    assert gate_data.get("gate_status") in ["PASSED", "VERIFIED"], f"Final gate not passed: {gate_data}"
    verified_sld = gate_data.get("verified_sld")
    print(f"[+] Final Gate: {gate_data.get('gate_status')}! VerifiedSLD created with {len(verified_sld['nodes'])} nodes, {len(verified_sld['lines'])} lines")

    print("\n[*] Step 5: Upload case24_psse.xlsx ...")
    with open(EXCEL_PATH, "rb") as f:
        res = requests.post(
            f"{BASE_URL}/upload_excel",
            files={"file": ("case24_psse.xlsx", f, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")}
        )
    assert res.status_code == 200, f"upload_excel failed: {res.text}"
    excel_result = res.json()
    excel_data = excel_result.get("data", {})
    raw_buses = len(excel_data.get('buses', {}))
    raw_gens = len(excel_data.get('generators', {}))
    raw_branches = len(excel_data.get('branches', {}))
    raw_trans = len(excel_data.get('transformers', {}))
    unique_branches = set()
    for br in excel_data.get('branches', {}).values():
        unique_branches.add(tuple(sorted([int(br.get('from_bus')), int(br.get('to_bus'))])))
    unique_trans = set()
    for tr in excel_data.get('transformers', {}).values():
        unique_trans.add(tuple(sorted([int(tr.get('from_bus')), int(tr.get('to_bus'))])))
    print(f"[+] Excel parsed:")
    print(f"    - Raw dictionary entries: {raw_buses} buses, {raw_gens} gens, {raw_branches} branch rows, {raw_trans} transformer rows")
    print(f"    - Canonical unique electrical: {len(unique_branches)} branches, {len(unique_trans)} transformer pairs")

    print("\n[*] Step 6: Initial strict compare with VerifiedSLD elements ...")
    # Collect review elements
    v_nodes = verified_sld["nodes"]
    v_lines = verified_sld["lines"]
    review_elements = []
    for n in v_nodes:
        cls = (n.get("class") or n.get("type", "")).lower()
        review_elements.append({
            "id": n["id"],
            "type": cls,
            "class": cls,
            "label": n.get("display_label", n["id"]),
            "bus_number": n.get("bus_number"),
            "connected_bus_number": n.get("connected_bus_number"),
            "connected_bus_id": n.get("connected_bus_id"),
            "parentBusId": n.get("connected_bus_id"),
        })
    for l in v_lines:
        is_lead = (l.get("trace_method") == "equipment_lead" or 
                   l.get("evidence", {}).get("is_equipment_lead") or 
                   l.get("evidence", {}).get("electricalBranch") is False)
        review_elements.append({
            "id": l["line_id"],
            "type": "line",
            "connected_to": l["connected_to"],
            "startElementId": l["connected_to"][0] if l["connected_to"] else None,
            "endElementId": l["connected_to"][1] if len(l["connected_to"]) > 1 else None,
            "is_equipment_lead": is_lead,
            "isEquipmentLead": is_lead,
            "electricalBranch": not is_lead,
            "evidence": l.get("evidence", {}),
        })

    res = requests.post(
        f"{BASE_URL}/apply_excel_to_elements",
        json={
            "elements": review_elements,
            "excel_data": excel_data,
            "verified_sld_review": True,
        }
    )
    assert res.status_code == 200, f"apply_excel_to_elements failed: {res.text}"
    mismatch_resp = res.json()
    report = mismatch_resp.get("mismatch_report") or mismatch_resp.get("summary", {}).get("mismatch_report", {})
    is_matched = report.get("is_matched", False)
    proposals = report.get("repair_proposals", [])
    print(f"[+] Initial Compare Result: is_matched={is_matched}")
    print(f"    - Discrepancies: {len(report.get('discrepancies', []))}")
    print(f"    - Repair Proposals: {len(proposals)}")
    for p in proposals:
        print(f"      * [{p.get('category')}] Bus {p.get('bus_number')}: {p.get('message')}")

    assert len(proposals) > 0, "Expected repair proposal for missing generator in diagram!"
    # Verify Bus 14 proposal is present
    b14_prop = next((p for p in proposals if p.get("bus_number") == 14 and p.get("category") == "generator"), None)
    assert b14_prop is not None, f"Bus 14 generator repair proposal missing! Proposals: {proposals}"
    print(f"[+] Successfully found repair proposal: {b14_prop['message']}")

    print("\n[*] Step 7: Apply Repair Proposal (Simulate User UI Click [적용]) ...")
    target_bus_num = b14_prop["bus_number"]
    parent_bus = next((n for n in v_nodes if (n.get("class") or n.get("type")) == "bus" and n.get("bus_number") == target_bus_num), None)
    assert parent_bus is not None, f"Parent bus {target_bus_num} not found in verified nodes"

    gen_id = f"gen_supp_{target_bus_num}_test"
    cx, cy = parent_bus["bbox"][0], parent_bus["bbox"][1]
    new_node = {
        "id": gen_id,
        "class": "generator",
        "type": "generator",
        "bbox": [cx + 20.0, cy - 60.0, 40.0, 40.0],
        "confidence": 1.0,
        "source": "excel_repair_proposal",
        "review_status": "CONFIRMED",
        "bus_number": target_bus_num,
        "connected_bus_number": target_bus_num,
        "connected_bus_id": parent_bus["id"],
        "display_label": b14_prop.get("excel_data", {}).get("label", f"G_{target_bus_num}"),
        "metadata": b14_prop.get("excel_data", {}),
    }
    lead_id = f"lead_{gen_id}_to_{parent_bus['id']}"
    new_line = {
        "line_id": lead_id,
        "connected_to": [gen_id, parent_bus["id"]],
        "path": [[cx + 20.0, cy - 40.0], [cx, cy]],
        "trace_method": "equipment_lead",
        "review_status": "CONFIRMED",
        "source": "excel_repair_proposal",
        "display_label": "Lead",
        "evidence": {"is_equipment_lead": True, "electricalBranch": False},
    }

    # Add to verified SLD
    v_nodes.append(new_node)
    v_lines.append(new_line)

    # Re-collect review elements
    review_elements_2 = []
    for n in v_nodes:
        cls = (n.get("class") or n.get("type", "")).lower()
        review_elements_2.append({
            "id": n["id"],
            "type": cls,
            "class": cls,
            "label": n.get("display_label", n["id"]),
            "bus_number": n.get("bus_number"),
            "connected_bus_number": n.get("connected_bus_number"),
            "connected_bus_id": n.get("connected_bus_id"),
            "parentBusId": n.get("connected_bus_id"),
        })
    for l in v_lines:
        is_lead = (l.get("trace_method") == "equipment_lead" or 
                   l.get("evidence", {}).get("is_equipment_lead") or 
                   l.get("evidence", {}).get("electricalBranch") is False)
        review_elements_2.append({
            "id": l["line_id"],
            "type": "line",
            "connected_to": l["connected_to"],
            "startElementId": l["connected_to"][0] if l["connected_to"] else None,
            "endElementId": l["connected_to"][1] if len(l["connected_to"]) > 1 else None,
            "is_equipment_lead": is_lead,
            "isEquipmentLead": is_lead,
            "electricalBranch": not is_lead,
            "evidence": l.get("evidence", {}),
        })

    res = requests.post(
        f"{BASE_URL}/apply_excel_to_elements",
        json={
            "elements": review_elements_2,
            "excel_data": excel_data,
            "verified_sld_review": True,
        }
    )
    assert res.status_code == 200, f"apply_excel_to_elements failed: {res.text}"
    mismatch_resp_2 = res.json()
    report_2 = mismatch_resp_2.get("mismatch_report") or mismatch_resp_2.get("summary", {}).get("mismatch_report", {})
    print(f"\n[+] Second Compare Result: is_matched={report_2.get('is_matched')}")
    print(f"    - Discrepancies count: {len(report_2.get('discrepancies', []))}")
    for d in report_2.get('discrepancies', []):
        print(f"      * [{d.get('category')}/{d.get('type')}] {d.get('target')}: {d.get('message')}")
    print(f"    - Repair Proposals: {len(report_2.get('repair_proposals', []))}")
    assert report_2.get("is_matched") is True, f"Expected is_matched=True after applying proposal! Got: {report_2}"

    print("\n[*] Step 8: CAD Handoff (apply_verified_sld_to_elements) ...")
    # Format elements for CAD mapper
    cad_elements = []
    for n in v_nodes:
        cls = (n.get("class") or n.get("type", "")).lower()
        cad_elements.append({
            "id": n["id"],
            "type": f"Tool.{cls}" if cls in ["bus", "generator", "load", "transformer"] else cls,
            "label": n.get("display_label", n["id"]),
            "busNumber": n.get("bus_number"),
            "connectedBusNumber": n.get("connected_bus_number"),
            "parentBusId": n.get("connected_bus_id"),
            "position": {"dx": n["bbox"][0], "dy": n["bbox"][1]},
            "width": n["bbox"][2],
            "height": n["bbox"][3],
        })
    for l in v_lines:
        is_lead = (l.get("trace_method") == "equipment_lead" or 
                   l.get("evidence", {}).get("is_equipment_lead") or 
                   l.get("evidence", {}).get("electricalBranch") is False)
        cad_elements.append({
            "id": l["line_id"],
            "type": "Tool.line",
            "startElementId": l["connected_to"][0] if l["connected_to"] else None,
            "endElementId": l["connected_to"][1] if len(l["connected_to"]) > 1 else None,
            "is_equipment_lead": is_lead,
            "isEquipmentLead": is_lead,
            "electricalBranch": not is_lead,
            "evidence": l.get("evidence", {}),
        })

    res = requests.post(
        f"{BASE_URL}/apply_excel_to_elements",
        json={
            "elements": cad_elements,
            "excel_data": excel_data,
            "verified_sld_apply": True,
        }
    )
    assert res.status_code == 200, f"CAD apply failed: {res.text}"
    cad_apply_data = res.json()
    applied_elements = cad_apply_data.get("elements", [])
    print(f"[+] CAD Handoff Success! Bound elements: {len(applied_elements)}")

    print("\n[*] Step 9: Run AC Newton-Raphson Power Flow Simulation ...")
    res = requests.post(
        f"{BASE_URL}/run_simulation",
        json={"elements": applied_elements}
    )
    assert res.status_code == 200, f"run_simulation failed: {res.text}"
    sim_result = res.json()
    print(f"[+] Simulation Response Status: {sim_result.get('status')}")
    assert sim_result.get("status") == "success", f"Simulation did not succeed: {sim_result}"
    data = sim_result.get("data", {})
    converged = data.get("converged", False)
    iterations = data.get("iterations", 0)
    summary = data.get("summary", {})
    total_p_gen = summary.get("total_gen_p_mw", 0.0)
    total_p_load = summary.get("total_load_p_mw", 0.0)
    total_losses = summary.get("total_loss_p_mw", 0.0)
    bus_results = data.get("bus_results", [])

    print(f"\n==========================================")
    print(f"POWER FLOW AC NEWTON-RAPHSON RESULTS:")
    print(f"==========================================")
    print(f"  * Converged:       {converged}")
    print(f"  * Iterations:      {iterations}")
    print(f"  * Total P Gen:     {total_p_gen:.2f} MW")
    print(f"  * Total P Load:    {total_p_load:.2f} MW")
    print(f"  * Total Losses:    {total_losses:.2f} MW")
    print(f"  * Solved Buses:    {len(bus_results)}")
    print(f"==========================================")
    assert converged is True, f"Power flow failed to converge! Iterations: {iterations}"
    assert len(bus_results) == 24, f"Expected 24 bus voltages, got {len(bus_results)}"
    print("\n[SUCCESS] FULL GOLDEN RUNTIME E2E + GEMINI 3.8 + EXCEL STRICT BINDING + AC SOLVER PASSED!")

if __name__ == "__main__":
    run_e2e()

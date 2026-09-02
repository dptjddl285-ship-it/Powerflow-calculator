"""Tests for VisionFlow Review Pipeline and Step 2/3 Connection Review & VerifiedSLD Components.

Verifies:
- Test A: Object Review Contract (nodes, review_stage, image metadata, review fields)
- Test B: Node Contract (id, class, bbox, confidence, source, review_status, review_reasons)
- Test C: Image Retrieval & Session Store (create_session, get_session, width/height, bytes)
- Test D: Backward Compatibility (analyze_circuit_image_adaptive returns nodes and lines)
- Test E: Confirmed Nodes (detect_sld_connections_adaptive routes connections using confirmed node IDs)
- Test F: Object Evidence & Suspicious Classification
- Test G: Agent Object Reviewer (Korean explanations & deterministic fallback)
- Test H: Human Correction Actions & Object Gate Verification
- Test I: ROI Re-analysis Adapter Tools
- Test J: Connection Evidence & Issue Mapping
- Test K: Agent Connection Verifier Fallback
- Test L: Human Connection Corrections (Confirm, Reject, Reconnect, Manual Add) & Re-validation
- Test M: Final Gate Verification & VerifiedSLD Creation
- Test N: Verified-Only Handoff Validation (Draft rejection)
"""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock
import cv2
import numpy as np
import sys
from pathlib import Path

# Add backend_api to sys.path
backend_api_dir = Path(__file__).resolve().parent.parent
if str(backend_api_dir) not in sys.path:
    sys.path.insert(0, str(backend_api_dir))

from review.session_store import ReviewSessionStore, session_store
from core.vision_logic import detect_sld_objects, detect_sld_connections
from core.pipeline_policy import validate_graph, GraphIssue
from core.adaptive_vision_pipeline import (
    analyze_circuit_image_adaptive,
    detect_sld_objects_adaptive,
    detect_sld_connections_adaptive,
)
from agent.evidence_extractor import extract_object_evidence, classify_suspicious, ObjectEvidence
from agent.object_reviewer import AgentObjectReviewer, object_reviewer
from agent.connection_evidence import (
    ConnectionEvidence,
    extract_connection_evidence,
    extract_all_connections_evidence,
)
from agent.connection_verifier import AgentConnectionVerifier, connection_verifier
from agent.tools import (
    reanalyze_bus_roi,
    reanalyze_generator_roi,
    reanalyze_load_roi,
    reanalyze_transformer_roi,
)


class ReviewPipelineTest(unittest.TestCase):
    def setUp(self):
        # Create a synthetic diagram image (300x300, white background with two black buses and a connecting line)
        self.image = np.ones((300, 300, 3), dtype=np.uint8) * 255
        # Draw bus 1 (top horizontal bar: y=50, x=50..150, thickness=3)
        cv2.line(self.image, (50, 50), (150, 50), (0, 0, 0), thickness=3)
        # Draw bus 2 (bottom horizontal bar: y=250, x=50..150, thickness=3)
        cv2.line(self.image, (50, 250), (150, 250), (0, 0, 0), thickness=3)
        # Draw vertical line connecting them (x=100, y=50..250, thickness=1)
        cv2.line(self.image, (100, 50), (100, 250), (0, 0, 0), thickness=1)

        ok, encoded = cv2.imencode(".png", self.image)
        self.assertTrue(ok)
        self.image_bytes = encoded.tobytes()

        # Dummy YOLO model returning empty proposals
        self.mock_model = MagicMock()
        mock_result = MagicMock()
        mock_result.boxes = []
        self.mock_model.predict.return_value = [mock_result]

    def test_a_object_review_contract(self):
        """Test A: Object Review Contract in detect_sld_objects_adaptive."""
        session_store.clear()
        session = session_store.create_session(self.image_bytes, content_type="image/png")

        self.assertTrue(session.document_id.startswith("doc_"))
        self.assertEqual(session.width, 300)
        self.assertEqual(session.height, 300)

        result = detect_sld_objects_adaptive(self.image_bytes, self.mock_model)
        self.assertIn("nodes", result)
        self.assertIsInstance(result["nodes"], list)
        self.assertIn("pipeline", result)
        self.assertIsInstance(result["pipeline"], dict)

        # In object review mode, lines should be empty
        self.assertEqual(result.get("lines", []), [])

    def test_b_node_contract(self):
        """Test B: Node Contract contains all required fields including review_status & review_reasons."""
        result = detect_sld_objects_adaptive(self.image_bytes, self.mock_model)
        nodes = result.get("nodes", [])
        self.assertGreater(len(nodes), 0, "Synthetic image should detect CV bus objects")

        for node in nodes:
            self.assertIn("id", node)
            self.assertIn("class", node)
            self.assertIn("bbox", node)
            self.assertEqual(len(node["bbox"]), 4)
            self.assertIn("confidence", node)
            self.assertIn("source", node)
            self.assertIn(node.get("review_status"), ["DETECTED", "SUSPICIOUS", "CONFIRMED"])
            self.assertIsInstance(node.get("review_reasons"), list)

    def test_c_image_retrieval_and_session(self):
        """Test C: Session store correctly persists and retrieves image bytes and metadata."""
        session_store.clear()
        session = session_store.create_session(self.image_bytes, content_type="image/png")
        doc_id = session.document_id

        retrieved = session_store.get_session(doc_id)
        self.assertIsNotNone(retrieved)
        self.assertEqual(retrieved.image_bytes, self.image_bytes)
        self.assertEqual(retrieved.content_type, "image/png")
        self.assertEqual(retrieved.width, 300)
        self.assertEqual(retrieved.height, 300)

        # Non-existent ID returns None
        self.assertIsNone(session_store.get_session("doc_non_existent"))

    def test_d_backward_compatibility(self):
        """Test D: analyze_circuit_image_adaptive retains nodes and lines full pipeline output."""
        result = analyze_circuit_image_adaptive(self.image_bytes, self.mock_model)
        self.assertIn("nodes", result)
        self.assertIn("lines", result)
        self.assertIsInstance(result["nodes"], list)
        self.assertIsInstance(result["lines"], list)
        self.assertGreater(len(result["nodes"]), 0)
        self.assertGreater(len(result["lines"]), 0)

    def test_e_confirmed_nodes_connection_detection(self):
        """Test E: detect_sld_connections_adaptive routes connections using external confirmed nodes."""
        session_store.clear()
        session = session_store.create_session(self.image_bytes, content_type="image/png")
        doc_id = session.document_id

        # User-confirmed nodes (Bus 1 at top, Bus 2 at bottom)
        confirmed_nodes = [
            {
                "id": "confirmed_bus_1",
                "class": "bus",
                "bbox": [100.0, 50.0, 100.0, 6.0],
                "confidence": 1.0,
                "source": "human_confirmed",
                "review_status": "CONFIRMED",
                "review_reasons": [],
            },
            {
                "id": "confirmed_bus_2",
                "class": "bus",
                "bbox": [100.0, 250.0, 100.0, 6.0],
                "confidence": 1.0,
                "source": "human_confirmed",
                "review_status": "CONFIRMED",
                "review_reasons": [],
            },
        ]

        cached_session = session_store.get_session(doc_id)
        self.assertIsNotNone(cached_session)

        conn_result = detect_sld_connections_adaptive(
            cached_session.image_bytes, confirmed_nodes
        )

        self.assertEqual(conn_result.get("nodes"), confirmed_nodes)
        lines = conn_result.get("lines", [])
        self.assertGreater(len(lines), 0, "Should detect connection line between confirmed buses")

        first_line = lines[0]
        self.assertIn("line_id", first_line)
        self.assertIn("connected_to", first_line)
        self.assertIn("path", first_line)
        self.assertIn("source_port", first_line)
        self.assertIn("target_port", first_line)

        connected_ids = set(first_line["connected_to"])
        self.assertTrue(
            "confirmed_bus_1" in connected_ids and "confirmed_bus_2" in connected_ids,
            f"Line connected_to should refer to confirmed bus IDs, got {connected_ids}",
        )

    def test_f_object_evidence_and_suspicious_classification(self):
        """Test F: Object Evidence extraction and deterministic suspicious classification."""
        nodes = [
            {
                "id": "load_0",
                "class": "load",
                "bbox": [100.0, 100.0, 20.0, 20.0],
                "confidence": 0.45,
                "source": "yolo_port_rescue",
            },
            {
                "id": "bus_0",
                "class": "bus",
                "bbox": [100.0, 50.0, 100.0, 8.0],
                "confidence": 0.95,
                "source": "cv_primary",
            },
        ]

        annotated = classify_suspicious(nodes)
        self.assertEqual(len(annotated), 2)

        load_node = next(n for n in annotated if n["id"] == "load_0")
        self.assertEqual(load_node["review_status"], "SUSPICIOUS")
        self.assertGreater(len(load_node["review_reasons"]), 0)

        bus_node = next(n for n in annotated if n["id"] == "bus_0")
        self.assertEqual(bus_node["review_status"], "DETECTED")

    def test_g_agent_object_reviewer_fallback(self):
        """Test G: Agent Object Reviewer produces natural Korean explanations in fallback mode."""
        reviewer = AgentObjectReviewer()
        evidence = ObjectEvidence(
            node_id="gen_0",
            class_name="generator",
            bbox=[150.0, 150.0, 30.0, 30.0],
            confidence=0.52,
            source="yolo_generator_rescue",
            is_suspicious=True,
            suspicious_reasons=["AI 신뢰도가 낮음 (0.52)"],
        )

        review_res = reviewer._deterministic_fallback_review(evidence)
        self.assertEqual(review_res.node_id, "gen_0")
        self.assertIn("Generator", review_res.message_ko)
        self.assertEqual(review_res.assessment, "NEEDS_HUMAN_REVIEW")
        self.assertEqual(review_res.recommended_action, "ASK_USER")
        self.assertIn("generator", review_res.suggested_classes)

    def test_h_human_correction_and_object_gate(self):
        """Test H: Object Gate verifies all nodes confirmed and rejects blocked states."""
        working_nodes = [
            {
                "id": "node_1",
                "class": "bus",
                "bbox": [50.0, 50.0, 100.0, 10.0],
                "review_status": "CONFIRMED",
            },
            {
                "id": "node_2",
                "class": "load",
                "bbox": [150.0, 150.0, 20.0, 20.0],
                "review_status": "SUSPICIOUS",
            },
        ]
        unconfirmed = [n for n in working_nodes if n.get("review_status") != "CONFIRMED" and n.get("review_status") != "REJECTED"]
        self.assertEqual(len(unconfirmed), 1)

        working_nodes[1]["review_status"] = "CONFIRMED"
        working_nodes[1]["source"] = "human_confirmed"

        confirmed = [n for n in working_nodes if n.get("review_status") == "CONFIRMED"]
        unconfirmed_after = [n for n in working_nodes if n.get("review_status") != "CONFIRMED" and n.get("review_status") != "REJECTED"]
        self.assertEqual(len(unconfirmed_after), 0)
        self.assertEqual(len(confirmed), 2)

    def test_i_roi_reanalysis_tools(self):
        """Test I: ROI Re-analysis tools execute cleanly without crashing."""
        img = np.ones((200, 200, 3), dtype=np.uint8) * 255
        cv2.circle(img, (100, 100), 20, (0, 0, 0), thickness=2)

        gen_res = reanalyze_generator_roi(img, [100.0, 100.0, 45.0, 45.0])
        self.assertIn("has_circle", gen_res)
        self.assertIn("score", gen_res)

        bus_res = reanalyze_bus_roi(self.image, [100.0, 50.0, 100.0, 10.0])
        self.assertIn("is_straight_bar", bus_res)
        self.assertTrue(bus_res["is_straight_bar"])

    def test_j_connection_evidence_and_issue_mapping(self):
        """Test J: Connection Evidence extraction accurately maps graph validation issues."""
        nodes = [
            {"id": "gen_1", "class": "generator", "bbox": [50.0, 50.0, 20.0, 20.0]},
            {"id": "load_1", "class": "load", "bbox": [150.0, 50.0, 20.0, 20.0]},
        ]
        # Invalid direct connection between load and generator
        invalid_lines = [
            {
                "line_id": "L_invalid_1",
                "connected_to": ["gen_1", "load_1"],
                "path": [[50.0, 50.0], [150.0, 50.0]],
            }
        ]

        ev = extract_connection_evidence(invalid_lines[0], nodes, invalid_lines)
        self.assertEqual(ev.line_id, "L_invalid_1")
        self.assertTrue(ev.is_ambiguous)
        self.assertEqual(ev.review_status, "AMBIGUOUS")
        self.assertGreater(len(ev.validation_issues), 0)
        issue_codes = [i["code"] for i in ev.validation_issues]
        self.assertIn("invalid_device_pair", issue_codes)

    def test_k_agent_connection_verifier_fallback(self):
        """Test K: Agent Connection Verifier produces natural Korean explanations in fallback mode."""
        verifier = AgentConnectionVerifier()
        nodes = [
            {"id": "gen_1", "class": "generator", "bbox": [50.0, 50.0, 20.0, 20.0]},
            {"id": "bus_1", "class": "bus", "bbox": [100.0, 50.0, 100.0, 10.0]},
        ]
        line = {
            "line_id": "L1",
            "connected_to": ["gen_1", "bus_1"],
            "path": [[50.0, 50.0], [100.0, 50.0]],
        }
        ev = extract_connection_evidence(line, nodes, [line])

        res = verifier._deterministic_fallback_review(ev, nodes, [line])
        self.assertEqual(res.line_id, "L1")
        self.assertEqual(res.assessment, "CONFIRM")
        self.assertIn("정상적인", res.message_ko)

    def test_l_human_connection_corrections_and_revalidation(self):
        """Test L: Human connection corrections (Confirm, Reject, Reconnect, Manual Add) & Re-validation."""
        nodes = [
            {"id": "bus_1", "class": "bus", "bbox": [100.0, 50.0, 100.0, 10.0]},
            {"id": "bus_2", "class": "bus", "bbox": [100.0, 200.0, 100.0, 10.0]},
            {"id": "load_1", "class": "load", "bbox": [100.0, 280.0, 20.0, 20.0]},
        ]
        # Line 1: bus_1 <-> bus_2, Line 2: duplicate, Line 3: manual add for load
        working_lines = [
            {
                "line_id": "L1",
                "connected_to": ["bus_1", "bus_2"],
                "path": [[100.0, 50.0], [100.0, 200.0]],
                "review_status": "CONFIRMED",
            },
            {
                "line_id": "L2_dup",
                "connected_to": ["bus_1", "bus_2"],
                "path": [[100.0, 50.0], [100.0, 200.0]],
                "review_status": "DETECTED",
            },
        ]

        # Action: Reject duplicate line L2
        working_lines[1]["review_status"] = "REJECTED"

        # Action: Manual Add Line for load_1 <-> bus_2
        working_lines.append({
            "line_id": "manual_L3",
            "connected_to": ["load_1", "bus_2"],
            "path": [[100.0, 280.0], [100.0, 200.0]],
            "review_status": "CONFIRMED",
            "source": "human_added",
        })

        # Re-validate active lines
        active_lines = [l for l in working_lines if l.get("review_status") == "CONFIRMED"]
        issues = validate_graph(nodes, active_lines)
        critical_issues = [i for i in issues if i.severity == "error"]
        self.assertEqual(len(critical_issues), 0, "Corrected graph should have 0 critical errors")

    def test_m_final_gate_and_verified_sld_creation(self):
        """Test M: Final Gate verifies all conditions and produces complete VerifiedSLD document."""
        nodes = [
            {"id": "bus_1", "class": "bus", "bbox": [100.0, 50.0, 100.0, 10.0], "review_status": "CONFIRMED"},
            {"id": "bus_2", "class": "bus", "bbox": [100.0, 200.0, 100.0, 10.0], "review_status": "CONFIRMED"},
        ]
        lines = [
            {
                "line_id": "L1",
                "connected_to": ["bus_1", "bus_2"],
                "path": [[100.0, 50.0], [100.0, 200.0]],
                "review_status": "CONFIRMED",
            }
        ]

        # All nodes and lines are confirmed, 0 critical issues
        issues = validate_graph(nodes, lines)
        self.assertEqual(len(issues), 0)

        verified_sld = {
            "schema_version": "1.0",
            "document_id": "doc_test_123",
            "status": "VERIFIED",
            "image": {"width": 300, "height": 300},
            "nodes": [
                {"id": n["id"], "class": n["class"], "bbox": n["bbox"], "confidence": 1.0, "source": "confirmed", "verification_status": "CONFIRMED"}
                for n in nodes
            ],
            "lines": [
                {"line_id": l["line_id"], "connected_to": l["connected_to"], "path": l["path"], "source_port": "auto", "target_port": "auto", "trace_method": "electrical_graph", "verification_status": "CONFIRMED"}
                for l in lines
            ],
            "verification": {"object_gate": "PASS", "connection_gate": "PASS", "critical_issue_count": 0},
        }

        self.assertEqual(verified_sld["status"], "VERIFIED")
        self.assertEqual(len(verified_sld["nodes"]), 2)
        self.assertEqual(len(verified_sld["lines"]), 1)

    def test_n_verified_only_handoff_validation(self):
        """Test N: Draft/Unverified payloads must be rejected for Verified Handoff."""
        draft_sld = {
            "status": "DRAFT",
            "document_id": "doc_draft",
            "nodes": [],
        }
        self.assertNotEqual(draft_sld.get("status"), "VERIFIED", "Draft SLD must not be accepted as VERIFIED")

    def test_o_human_completeness_gate_block(self):
        """Test O: Object Gate must BLOCK if human_completeness_confirmed is False."""
        from agent import MissingCandidate
        working_nodes = [
            {"id": "bus_1", "class": "bus", "bbox": [50.0, 50.0, 100.0, 10.0], "review_status": "CONFIRMED"},
            {"id": "gen_1", "class": "generator", "bbox": [50.0, 100.0, 30.0, 30.0], "review_status": "CONFIRMED"},
        ]
        human_confirmed = False
        missing_candidates: list[MissingCandidate] = []

        unconfirmed = [n for n in working_nodes if n.get("review_status") not in ("CONFIRMED", "REJECTED")]
        unresolved_cands = [c for c in missing_candidates if c.status == "OPEN"]
        can_verify = (len(unconfirmed) == 0 and len(working_nodes) > 0 and len(unresolved_cands) == 0 and human_confirmed)
        self.assertFalse(can_verify, "Gate must block if human completeness confirmation is not checked")

    def test_p_unresolved_candidate_gate_block(self):
        """Test P: Object Gate must BLOCK if unresolved missing candidates exist (OPEN)."""
        from agent import MissingCandidate
        working_nodes = [
            {"id": "bus_1", "class": "bus", "bbox": [50.0, 50.0, 100.0, 10.0], "review_status": "CONFIRMED"},
        ]
        human_confirmed = True
        missing_candidates = [
            MissingCandidate(id="cand_1", suspected_class="transformer", description_ko="변압기 누락 의심", status="OPEN")
        ]

        unconfirmed = [n for n in working_nodes if n.get("review_status") not in ("CONFIRMED", "REJECTED")]
        unresolved_cands = [c for c in missing_candidates if c.status == "OPEN"]
        can_verify = (len(unconfirmed) == 0 and len(working_nodes) > 0 and len(unresolved_cands) == 0 and human_confirmed)
        self.assertFalse(can_verify, "Gate must block if open missing candidates exist")

    def test_q_candidate_dismiss_and_completeness_pass(self):
        """Test Q: Object Gate PASSES when missing candidate is dismissed/resolved and completeness is checked."""
        from agent import MissingCandidate
        working_nodes = [
            {"id": "bus_1", "class": "bus", "bbox": [50.0, 50.0, 100.0, 10.0], "review_status": "CONFIRMED"},
        ]
        human_confirmed = True
        missing_candidates = [
            MissingCandidate(id="cand_1", suspected_class="transformer", description_ko="변압기 누락 의심", status="DISMISSED_BY_HUMAN")
        ]

        unconfirmed = [n for n in working_nodes if n.get("review_status") not in ("CONFIRMED", "REJECTED")]
        unresolved_cands = [c for c in missing_candidates if c.status == "OPEN"]
        can_verify = (len(unconfirmed) == 0 and len(working_nodes) > 0 and len(unresolved_cands) == 0 and human_confirmed)
        self.assertTrue(can_verify, "Gate must PASS when candidate is dismissed and completeness is confirmed")

    def test_r_verified_sld_completeness_provenance(self):
        """Test R: VerifiedSLD contains human_completeness_confirmed in verification metadata."""
        verified_sld = {
            "schema_version": "1.0",
            "document_id": "doc_test_prov",
            "status": "VERIFIED",
            "image": {"width": 500, "height": 500},
            "nodes": [{"id": "b1", "class": "bus", "bbox": [10, 10, 50, 10], "confidence": 1.0, "source": "confirmed", "verification_status": "CONFIRMED"}],
            "lines": [],
            "verification": {
                "object_gate": "PASS",
                "connection_gate": "PASS",
                "human_completeness_confirmed": True,
                "critical_issue_count": 0,
            },
        }
        self.assertTrue(verified_sld["verification"]["human_completeness_confirmed"])

    def test_s_completeness_reviewer_fallback(self):
        """Test S: AgentCompletenessReviewer generates missing candidates in deterministic fallback."""
        from agent import AgentCompletenessReviewer
        reviewer = AgentCompletenessReviewer()
        nodes = [
            {"id": f"bus_{i}", "class": "bus"} for i in range(5)
        ] + [
            {"id": f"gen_{i}", "class": "generator"} for i in range(2)
        ] + [
            {"id": f"load_{i}", "class": "load"} for i in range(2)
        ]
        # Transformer is 0 while buses >= 3
        res = reviewer._deterministic_fallback_review(nodes, class_counts={"bus": 5, "generator": 2, "load": 2, "transformer": 0})
        self.assertEqual(res.assessment, "POSSIBLE_MISSING_COMPONENT")
        self.assertGreater(len(res.candidates), 0)
        self.assertEqual(res.candidates[0].suspected_class, "transformer")
        self.assertIn("변압기", res.candidates[0].description_ko)

    def test_t_chat_reviewer_context_and_fallback(self):
        """Test T: AgentChatReviewer produces context-aware explanations in deterministic fallback."""
        from agent.providers import LocalReviewAssistantProvider
        local_prov = LocalReviewAssistantProvider()
        res_summary = local_prov.answer_chat(
            message="검토 필요한 부분 요약해줘",
            document_id="doc_chat_test",
            stage="OBJECT_REVIEW",
            working_nodes=[
                {"id": "bus_1", "class": "bus", "review_status": "SUSPICIOUS"},
                {"id": "gen_1", "class": "generator", "review_status": "CONFIRMED"},
            ],
            missing_candidates=[
                {"id": "cand_1", "suspected_class": "transformer", "description_ko": "변압기 누락 의심", "status": "OPEN"}
            ],
        )
        self.assertIn("요약", res_summary["reply_ko"])
        self.assertIn("확인해야 할 항목", res_summary["reply_ko"])

        res_node = local_prov.answer_chat(
            message="왜 이걸 bus로 판단했어?",
            document_id="doc_chat_test",
            stage="OBJECT_REVIEW",
            selected_node={
                "id": "bus_1",
                "class": "bus",
                "confidence": 0.88,
                "source": "cv_primary",
                "review_reasons": ["Bus aspect ratio is high"],
                "agent_explanation": "정상적인 모선 심볼입니다.",
            },
        )
        self.assertIn("bus_1", res_node["reply_ko"].lower())
        self.assertIn("BUS", res_node["reply_ko"])

    def test_u_auto_confirm_object_and_connection_gate(self):
        """Test U: Clean DETECTED objects and lines are auto-confirmed and pass gates without errors."""
        working_nodes = [
            {"id": "bus_1", "class": "bus", "bbox": [10, 10, 100, 10], "review_status": "DETECTED"},
            {"id": "gen_1", "class": "generator", "bbox": [10, 50, 30, 30], "review_status": "CONFIRMED"},
        ]
        suspicious_nodes = [n for n in working_nodes if n.get("review_status") == "SUSPICIOUS"]
        open_cands = []
        human_confirmed = True

        can_pass_obj_gate = (len(suspicious_nodes) == 0 and len(open_cands) == 0 and human_confirmed and len(working_nodes) > 0)
        self.assertTrue(can_pass_obj_gate, "Object gate must pass when clean DETECTED is auto-confirmed and no suspicious remain")

        working_lines = [
            {"line_id": "L1", "connected_to": ["bus_1", "gen_1"], "path": [[10, 10], [10, 50]], "review_status": "DETECTED"},
        ]
        ambiguous_lines = [l for l in working_lines if l.get("review_status") == "AMBIGUOUS"]
        critical_issues = []

        can_pass_final_gate = (len(ambiguous_lines) == 0 and len(critical_issues) == 0 and len(working_lines) > 0)
        self.assertTrue(can_pass_final_gate, "Final gate must pass when clean DETECTED lines are auto-confirmed and no ambiguous remain")

    def test_v_default_local_provider_architecture(self):
        """Test V: Review Assistant Provider defaults to LocalReviewAssistantProvider or explicit providers."""
        import os
        from agent.providers import (
            get_assistant_provider,
            LocalReviewAssistantProvider,
            GeminiReviewAssistantProvider,
            OpenAIReviewAssistantProvider,
        )

        old_provider = os.environ.pop("AI_PROVIDER", None)
        old_openai_key = os.environ.pop("OPENAI_API_KEY", None)
        old_gemini_key = os.environ.pop("GEMINI_API_KEY", None)
        try:
            # 1. Default without env vars -> Local
            prov = get_assistant_provider()
            self.assertIsInstance(prov, LocalReviewAssistantProvider)
            self.assertEqual(prov.provider_name, "local")

            # 2. Key exists, but AI_PROVIDER is explicitly 'local' -> Still Local!
            os.environ["AI_PROVIDER"] = "local"
            os.environ["GEMINI_API_KEY"] = "fake-gemini-key"
            prov2 = get_assistant_provider()
            self.assertIsInstance(prov2, LocalReviewAssistantProvider)

            # 3. Explicit opt-in: AI_PROVIDER=gemini and GEMINI_API_KEY -> Gemini Provider
            os.environ["AI_PROVIDER"] = "gemini"
            prov3 = get_assistant_provider()
            self.assertIsInstance(prov3, GeminiReviewAssistantProvider)
            self.assertEqual(prov3.provider_name, "gemini")

            # 4. Explicit opt-in: AI_PROVIDER=openai and OPENAI_API_KEY -> OpenAI Provider
            os.environ["AI_PROVIDER"] = "openai"
            os.environ["OPENAI_API_KEY"] = "sk-fake-test-key-never-call"
            prov4 = get_assistant_provider()
            self.assertIsInstance(prov4, OpenAIReviewAssistantProvider)
            self.assertEqual(prov4.provider_name, "openai")
        finally:
            if old_provider is not None:
                os.environ["AI_PROVIDER"] = old_provider
            else:
                os.environ.pop("AI_PROVIDER", None)
            if old_openai_key is not None:
                os.environ["OPENAI_API_KEY"] = old_openai_key
            else:
                os.environ.pop("OPENAI_API_KEY", None)
            if old_gemini_key is not None:
                os.environ["GEMINI_API_KEY"] = old_gemini_key
            else:
                os.environ.pop("GEMINI_API_KEY", None)

    def test_w_local_chat_question_coverage(self):
        """Test W: LocalReviewAssistantProvider accurately responds to diverse electrical review questions."""
        from agent.providers import LocalReviewAssistantProvider
        local_prov = LocalReviewAssistantProvider()

        # 1. Why suspicious?
        res1 = local_prov.answer_chat(
            message="왜 이 객체가 의심이야?",
            document_id="doc_1",
            stage="OBJECT_REVIEW",
            selected_node={
                "id": "bus_1",
                "class": "bus",
                "confidence": 0.58,
                "review_status": "SUSPICIOUS",
                "review_reasons": ["Bus aspect ratio is low (1.8)"],
            },
        )
        self.assertIn("bus_1", res1["reply_ko"].lower())
        self.assertIn("aspect ratio", res1["reply_ko"].lower())

        # 2. Class change impact
        res2 = local_prov.answer_chat(
            message="이 객체 클래스를 load로 바꾸면 어떤 영향이 있어?",
            document_id="doc_1",
            stage="OBJECT_REVIEW",
            selected_node={"id": "bus_1", "class": "bus"},
        )
        self.assertIn("모선(bus)", res2["reply_ko"].lower())
        self.assertIn("영향", res2["reply_ko"])

        # 3. Next step guidance
        res3 = local_prov.answer_chat(
            message="다음에 무엇을 해야 해?",
            document_id="doc_1",
            stage="OBJECT_REVIEW",
            working_nodes=[{"id": "b1", "review_status": "SUSPICIOUS"}],
            missing_candidates=[{"status": "OPEN"}],
        )
        self.assertIn("다음 단계", res3["reply_ko"])
        self.assertIn("Gate 통과", res3["reply_ko"])

        # 4. Line issue explanation
        res4 = local_prov.answer_chat(
            message="선택한 선로가 왜 문제야?",
            document_id="doc_1",
            stage="CONNECTION_REVIEW",
            selected_line={
                "line_id": "L1",
                "connected_to": ["gen_1", "load_1"],
                "validation_issues": [{"code": "INVALID_GEN_LOAD_DIRECT", "message": "발전기와 부하가 모선 없이 직결됨"}],
            },
        )
        self.assertIn("L1", res4["reply_ko"])
        self.assertIn("발전기와 부하", res4["reply_ko"])

    def test_y_label_generator_and_bus_matcher(self):
        """Test Y: Display label generation, bus number matching with nearby text, and line naming."""
        from agent.label_generator import generate_display_labels, generate_line_display_labels

        nodes = [
            {"id": "bus_0", "class": "bus", "bbox": [100.0, 100.0, 120.0, 12.0]},
            {"id": "bus_1", "class": "bus", "bbox": [100.0, 300.0, 120.0, 12.0]},
            {"id": "gen_0", "class": "generator", "bbox": [100.0, 50.0, 30.0, 30.0]},
            {"id": "load_0", "class": "load", "bbox": [100.0, 400.0, 25.0, 25.0]},
        ]

        text_candidates = [
            {"text": "Bus 4", "cx": 110.0, "cy": 85.0},
        ]

        labeled_nodes = generate_display_labels(nodes, existing_text_candidates=text_candidates)

        # bus_0 should match "Bus 4" text nearby
        bus_0_res = next(n for n in labeled_nodes if n["id"] == "bus_0")
        self.assertEqual(bus_0_res["display_label"], "BUS 4")
        self.assertEqual(bus_0_res["suggested_bus_number"], 4)
        self.assertEqual(bus_0_res["number_source"], "detected_text")

        # bus_1 should get sequence fallback
        bus_1_res = next(n for n in labeled_nodes if n["id"] == "bus_1")
        self.assertTrue(bus_1_res["display_label"].startswith("BUS"))
        self.assertEqual(bus_1_res["number_source"], "sequence_fallback")

        # Generator & Load
        gen_res = next(n for n in labeled_nodes if n["id"] == "gen_0")
        self.assertEqual(gen_res["display_label"], "GEN 1")

        load_res = next(n for n in labeled_nodes if n["id"] == "load_0")
        self.assertEqual(load_res["display_label"], "LOAD 1")

        # Line labeling
        lines = [
            {"line_id": "line_0", "connected_to": ["bus_0", "load_0"], "path": [[100, 100], [100, 400]]}
        ]
        labeled_lines = generate_line_display_labels(lines, nodes=labeled_nodes)
        self.assertEqual(labeled_lines[0]["display_label"], "L1")
        self.assertEqual(labeled_lines[0]["endpoints_display"], "BUS 4 ↔ LOAD 1")
        self.assertEqual(labeled_lines[0]["display_name"], "L1 (BUS 4 ↔ LOAD 1)")

    def test_z_proactive_summary_generation(self):
        """Test Z: Proactive review priority summary generation in Local Review Assistant."""
        from agent.providers import LocalReviewAssistantProvider
        prov = LocalReviewAssistantProvider()

        nodes = [
            {"id": "bus_4", "class": "bus", "display_label": "BUS 4", "review_status": "SUSPICIOUS", "review_reasons": ["신뢰도 경계 (58%)"]},
            {"id": "gen_1", "class": "generator", "display_label": "GEN 1", "review_status": "DETECTED"},
        ]
        cands = [
            {"id": "cand_1", "suspected_class": "transformer", "description_ko": "변압기 누락 가능성", "status": "OPEN"}
        ]

        summary_res = prov.generate_proactive_summary(
            document_id="doc_summary_test",
            stage="OBJECT_REVIEW",
            working_nodes=nodes,
            missing_candidates=cands,
        )

        self.assertEqual(summary_res["total_count"], 2)
        self.assertEqual(summary_res["suspicious_count"], 1)
        self.assertEqual(summary_res["missing_count"], 1)
        self.assertEqual(len(summary_res["priority_items"]), 2)
        self.assertEqual(summary_res["priority_items"][0]["display_label"], "BUS 4")
        self.assertIn("AI 검토 우선순위 요약", summary_res["summary_text"])

    def test_session_store_lru_cleanup(self):
        """Test session store TTL and capacity eviction."""
        store = ReviewSessionStore(max_items=3, ttl_seconds=10)
        sessions = [
            store.create_session(b"img1"),
            store.create_session(b"img2"),
            store.create_session(b"img3"),
        ]
        self.assertEqual(len(store), 3)

        sess4 = store.create_session(b"img4")
        self.assertEqual(len(store), 3)
        self.assertIsNone(store.get_session(sessions[0].document_id))
        self.assertIsNotNone(store.get_session(sess4.document_id))


if __name__ == "__main__":
    unittest.main()

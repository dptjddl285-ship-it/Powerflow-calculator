"""Unit tests for PowerLens Lensy Agent Core V2 Foundation.

Covers:
- TEST 1: Canonical response schema validation (모든 필수 필드 존재, null-safety)
- TEST 2: Action Mode classification (EXECUTE vs GUIDE)
- TEST 3: Action allow-list enforcement (unknown action -> None)
- TEST 4: Mutation protection (circuit edits -> CONFIRM_REQUIRED, action_id is None)
- TEST 5: Fabricated target filtering (unregistered target IDs dropped)
- TEST 6: Proactive summary reasoning (Local and Gemini schema compliance)
- TEST 7: Centralized model configuration (gemini-3.8-flash primary, gemini-3.5-flash-lite fallback)
- TEST 8: Gemini Provider fallback chain (mock primary error -> fallback invoked)
- TEST 9: Evidence summary consistency (count matches working state)
- TEST 10: System knowledge consistency (ALLOW_LISTED_ACTIONS and constants match)
"""
import json
import os
import sys
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

# Add backend_api to sys.path
backend_api_dir = Path(__file__).resolve().parent.parent
if str(backend_api_dir) not in sys.path:
    sys.path.insert(0, str(backend_api_dir))

from core.model_config import (
    DEFAULT_GEMINI_FALLBACK_MODEL,
    DEFAULT_GEMINI_MODEL,
    get_gemini_fallback_model_name,
    get_gemini_model_name,
)
from agent.system_knowledge import (
    ALLOW_LISTED_ACTIONS,
    CANONICAL_RESPONSE_SCHEMA,
    VALID_ACTION_MODES,
    VALID_DECISIONS,
)
from agent.providers import (
    GeminiReviewAssistantProvider,
    LocalReviewAssistantProvider,
    sanitize_and_validate_agent_response,
)


class AgentCoreV2Test(unittest.TestCase):
    def setUp(self):
        self.local_prov = LocalReviewAssistantProvider()

    def test_01_canonical_response_schema_validation(self):
        """TEST 1: Canonical response schema validation (all required keys present and safe)."""
        raw = {
            "reply_ko": "검토를 시작합니다.",
            "decision": "PROCEED",
            "intent": "TEST_INTENT",
        }
        res = sanitize_and_validate_agent_response(
            raw,
            user_message="테스트",
            working_nodes=[{"id": "bus_1", "review_status": "NORMAL"}],
            working_lines=[],
            missing_candidates=[],
            topology_issues=[],
            stage="OBJECT_REVIEW",
        )
        self.assertEqual(res["decision"], "PROCEED")
        self.assertEqual(res["intent"], "TEST_INTENT")
        self.assertIn("action_mode", res)
        self.assertIn(res["action_mode"], VALID_ACTION_MODES)
        self.assertIn("action_id", res)
        self.assertIsInstance(res["action_params"], dict)
        self.assertIn("highlight_target", res)
        self.assertIsInstance(res["focus_targets"], list)
        self.assertIsInstance(res["evidence_summary"], dict)
        self.assertEqual(res["evidence_summary"]["suspicious_count"], 0)
        self.assertEqual(res["evidence_summary"]["missing_count"], 0)
        self.assertIn("summary_text", res)

    def test_02_action_mode_classification(self):
        """TEST 2: Action Mode classification: EXECUTE vs GUIDE based on user intent."""
        # 1. Direct execution command
        res_exec = self.local_prov.answer_chat(
            message="조류계산 실행해줘",
            document_id="doc_test",
            stage="POWERFLOW_READY",
        )
        self.assertEqual(res_exec["action_mode"], "EXECUTE")
        self.assertEqual(res_exec["action_id"], "RUN_POWER_FLOW")

        # 2. Location question -> GUIDE
        res_guide1 = self.local_prov.answer_chat(
            message="조류계산 어디서 해?",
            document_id="doc_test",
            stage="POWERFLOW_READY",
        )
        self.assertEqual(res_guide1["action_mode"], "GUIDE")
        self.assertEqual(res_guide1["action_id"], "RUN_POWER_FLOW")

        # 3. Button location question -> GUIDE
        res_guide2 = self.local_prov.answer_chat(
            message="조류계산 실행 버튼 어디야?",
            document_id="doc_test",
            stage="POWERFLOW_READY",
        )
        self.assertEqual(res_guide2["action_mode"], "GUIDE")

    def test_03_action_allow_list_enforcement(self):
        """TEST 3: Action allow-list enforcement (arbitrary actions set to None)."""
        raw = {
            "reply_ko": "알 수 없는 작업",
            "action_mode": "EXECUTE",
            "action_id": "DELETE_DATABASE_UNAUTHORIZED",
        }
        res = sanitize_and_validate_agent_response(raw, "테스트")
        self.assertIsNone(res["action_id"])

        # Valid action is preserved
        raw_valid = {
            "reply_ko": "조류계산 실행",
            "action_mode": "EXECUTE",
            "action_id": "RUN_POWER_FLOW",
        }
        res_valid = sanitize_and_validate_agent_response(raw_valid, "조류계산")
        self.assertEqual(res_valid["action_id"], "RUN_POWER_FLOW")

    def test_04_mutation_protection(self):
        """TEST 4: Mutation protection (circuit mutations require confirmation)."""
        # Node class change request
        res1 = self.local_prov.answer_chat(
            message="모선 1번을 부하로 변경해줘",
            document_id="doc_test",
            stage="OBJECT_REVIEW",
        )
        self.assertEqual(res1["action_mode"], "CONFIRM_REQUIRED")
        self.assertIsNone(res1["action_id"])

        # Line deletion request
        res2 = self.local_prov.answer_chat(
            message="선로 2번 삭제해줘",
            document_id="doc_test",
            stage="CONNECTION_REVIEW",
        )
        self.assertEqual(res2["action_mode"], "CONFIRM_REQUIRED")
        self.assertIsNone(res2["action_id"])

    def test_05_fabricated_target_filtering(self):
        """TEST 5: Fabricated target prevention (fabricated targets dropped)."""
        raw = {
            "reply_ko": "의심 객체 확인",
            "focus_targets": [
                {"type": "OBJECT", "id": "bus_1", "reason": "정상 모선"},
                {"type": "OBJECT", "id": "node_999", "reason": "조작된 가상 모선"},
                {"type": "LINE", "id": "line_fake", "reason": "가상 선로"},
            ],
        }
        res = sanitize_and_validate_agent_response(
            raw,
            user_message="확인",
            working_nodes=[{"id": "bus_1", "class": "bus"}],
            working_lines=[{"line_id": "line_1"}],
        )
        focus_ids = [t["id"] for t in res["focus_targets"]]
        self.assertIn("bus_1", focus_ids)
        self.assertNotIn("node_999", focus_ids)
        self.assertNotIn("line_fake", focus_ids)

    def test_06_proactive_summary_reasoning(self):
        """TEST 6: Proactive summary reasoning outputs canonical response schema."""
        summary = self.local_prov.generate_proactive_summary(
            document_id="doc_sum",
            stage="OBJECT_REVIEW",
            working_nodes=[
                {"id": "bus_1", "review_status": "SUSPICIOUS", "review_reasons": ["비율 경계"]},
                {"id": "gen_1", "review_status": "CONFIRMED"},
            ],
            missing_candidates=[
                {"id": "c1", "suspected_class": "transformer", "description_ko": "누락 의심", "status": "OPEN"}
            ],
        )
        self.assertIn("decision", summary)
        self.assertIn(summary["decision"], VALID_DECISIONS)
        self.assertIn("action_mode", summary)
        self.assertIn("reply_ko", summary)
        self.assertIn("summary_text", summary)
        self.assertEqual(summary["evidence_summary"]["suspicious_count"], 1)
        self.assertEqual(summary["evidence_summary"]["missing_count"], 1)

    def test_07_centralized_model_configuration(self):
        """TEST 7: Centralized model configuration resolves primary and fallback defaults."""
        with patch.dict(os.environ, {}, clear=True):
            primary = get_gemini_model_name()
            fallback = get_gemini_fallback_model_name()
            self.assertEqual(primary, "gemini-3.8-flash")
            self.assertEqual(fallback, "gemini-3.5-flash-lite")

        # Environmental override check
        with patch.dict(os.environ, {"GEMINI_MODEL": "custom-gemini-test", "GEMINI_FALLBACK_MODEL": "custom-fallback-test"}):
            self.assertEqual(get_gemini_model_name(), "custom-gemini-test")
            self.assertEqual(get_gemini_fallback_model_name(), "custom-fallback-test")

    def test_08_gemini_provider_fallback_chain(self):
        """TEST 8: Gemini Provider fallback chain switches to fallback model when primary fails."""
        prov = GeminiReviewAssistantProvider(
            api_key="test_dummy_key",
            model_name="gemini-3.8-flash",
            fallback_model_name="gemini-3.5-flash-lite",
        )
        self.assertEqual(prov.primary_model_name, "gemini-3.8-flash")
        self.assertEqual(prov.fallback_model_name, "gemini-3.5-flash-lite")

        # Mock urllib to fail on primary and succeed on fallback
        def mock_urlopen(req, timeout=25.0):
            url = req.full_url
            if "gemini-3.8-flash" in url:
                import urllib.error
                raise urllib.error.HTTPError(url, 429, "Too Many Requests", {}, None)
            elif "gemini-3.5-flash-lite" in url:
                mock_resp = MagicMock()
                mock_resp.read.return_value = b'{"candidates": [{"content": {"parts": [{"text": "{\\"reply_ko\\": \\"Fallback response\\", \\"decision\\": \\"PROCEED\\", \\"action_mode\\": \\"NONE\\"}"}]}}]}'
                mock_resp.__enter__.return_value = mock_resp
                return mock_resp
            raise ValueError(f"Unexpected url {url}")

        with patch("urllib.request.urlopen", side_effect=mock_urlopen):
            reply, active_model, is_fallback = prov._call_gemini_with_fallback(
                system_instruction="sys",
                contents=[{"role": "user", "parts": [{"text": "hi"}]}],
            )
            self.assertTrue(is_fallback)
            self.assertEqual(active_model, "gemini-3.5-flash-lite")
            self.assertIn("Fallback response", reply)

    def test_09_evidence_summary_consistency(self):
        """TEST 9: Evidence summary consistency matches working list counts."""
        nodes = [
            {"id": "b1", "review_status": "SUSPICIOUS"},
            {"id": "b2", "review_status": "SUSPICIOUS"},
            {"id": "g1", "review_status": "CONFIRMED"},
        ]
        lines = [
            {"line_id": "l1", "review_status": "AMBIGUOUS"},
            {"line_id": "l2", "review_status": "CONFIRMED"},
        ]
        cands = [
            {"id": "c1", "status": "OPEN"},
        ]
        issues = [
            {"line_id": "l1", "severity": "error", "message": "ERR1"},
        ]
        res = sanitize_and_validate_agent_response(
            {"reply_ko": "결과"},
            "상태",
            working_nodes=nodes,
            working_lines=lines,
            missing_candidates=cands,
            topology_issues=issues,
        )
        ev = res["evidence_summary"]
        self.assertEqual(ev["suspicious_count"], 2)
        self.assertEqual(ev["ambiguous_count"], 1)
        self.assertEqual(ev["missing_count"], 1)
        self.assertEqual(ev["topology_error_count"], 1)

    def test_10_system_knowledge_consistency(self):
        """TEST 10: System knowledge constants match allow-list and response schema definitions."""
        self.assertIn("RUN_POWER_FLOW", ALLOW_LISTED_ACTIONS)
        self.assertIn("SHOW_POWER_FLOW_RESULTS", ALLOW_LISTED_ACTIONS)
        self.assertIn("GO_HOME", ALLOW_LISTED_ACTIONS)
        self.assertIn("COMPLETE_CURRENT_STAGE", ALLOW_LISTED_ACTIONS)
        self.assertIn("OPEN_EXCEL_PICKER", ALLOW_LISTED_ACTIONS)
        self.assertIn("HANDOFF_TO_CANVAS", ALLOW_LISTED_ACTIONS)
        self.assertIn("SHOW_FLOW_DIRECTION", ALLOW_LISTED_ACTIONS)
        self.assertIn("HIDE_FLOW_DIRECTION", ALLOW_LISTED_ACTIONS)
        self.assertIn("SHOW_VALUE_LABELS", ALLOW_LISTED_ACTIONS)
        self.assertIn("HIDE_VALUE_LABELS", ALLOW_LISTED_ACTIONS)

        self.assertIn("EXECUTE", VALID_ACTION_MODES)
        self.assertIn("GUIDE", VALID_ACTION_MODES)
        self.assertIn("CONFIRM_REQUIRED", VALID_ACTION_MODES)
        self.assertIn("NONE", VALID_ACTION_MODES)

    def test_11_llm_proceed_normalized_to_human_check_when_suspicious_exists(self):
        """TEST 11: LLM returned PROCEED with suspicious_count 0, but server recalculates and forces HUMAN_CHECK."""
        raw_llm_hallucination = {
            "reply_ko": "모든 객체가 정상입니다.",
            "decision": "PROCEED",
            "evidence_summary": {
                "suspicious_count": 0,
                "missing_count": 0,
                "ambiguous_count": 0,
                "topology_error_count": 0,
            },
        }
        actual_nodes = [
            {"id": "bus_1", "review_status": "SUSPICIOUS", "review_reasons": ["비율 경계"]},
            {"id": "gen_1", "review_status": "CONFIRMED"},
        ]
        res = sanitize_and_validate_agent_response(
            raw_llm_hallucination,
            user_message="상태 확인해줘",
            working_nodes=actual_nodes,
            working_lines=[],
            missing_candidates=[],
            topology_issues=[],
        )
        # Server MUST overwrite evidence_summary and override PROCEED to HUMAN_CHECK
        self.assertEqual(res["evidence_summary"]["suspicious_count"], 1)
        self.assertEqual(res["decision"], "HUMAN_CHECK")

    def test_12_fake_highlight_target_sanitized_to_none(self):
        """TEST 12: Fake or unlisted highlight_target is stripped to None."""
        raw = {
            "reply_ko": "버튼 안내",
            "highlight_target": "fabricated_magic_button_xyz",
        }
        res = sanitize_and_validate_agent_response(raw, "안내")
        self.assertIsNone(res["highlight_target"])

        # Legitimate allow-listed highlight target is preserved
        raw_valid = {
            "reply_ko": "조류계산 버튼 안내",
            "highlight_target": "final_powerflow",
        }
        res_valid = sanitize_and_validate_agent_response(raw_valid, "안내")
        self.assertEqual(res_valid["highlight_target"], "final_powerflow")

    def test_13_line_type_with_node_id_dropped_from_focus_targets(self):
        """TEST 13: Strict focus target validation drops mismatch where LINE type contains a node ID."""
        raw = {
            "reply_ko": "포커스 타깃 검토",
            "focus_targets": [
                # Wrong: type is LINE, but 'bus_1' is a node ID, not in working_lines!
                {"type": "LINE", "id": "bus_1", "reason": "타입 불일치 타깃"},
                # Correct LINE target
                {"type": "LINE", "id": "line_101", "reason": "정상 선로 타깃"},
                # Correct OBJECT target
                {"type": "OBJECT", "id": "bus_1", "reason": "정상 모선 타깃"},
            ],
        }
        res = sanitize_and_validate_agent_response(
            raw,
            user_message="타깃 확인",
            working_nodes=[{"id": "bus_1", "review_status": "NORMAL"}],
            working_lines=[{"line_id": "line_101", "review_status": "NORMAL"}],
        )
        focused_targets = res["focus_targets"]
        # bus_1 with LINE type must NOT be present
        line_targets = [t for t in focused_targets if t["type"] == "LINE"]
        self.assertEqual(len(line_targets), 1)
        self.assertEqual(line_targets[0]["id"], "line_101")

        obj_targets = [t for t in focused_targets if t["type"] == "OBJECT"]
        self.assertEqual(len(obj_targets), 1)
        self.assertEqual(obj_targets[0]["id"], "bus_1")

    def test_14_excel_addition_vs_line_addition_distinction(self):
        """TEST 14: Distinguishes '엑셀 추가해줘' (Safe Action) from '선로 추가해줘' (CONFIRM_REQUIRED)."""
        # 1. '엑셀 추가해줘' must be Safe Action EXECUTE OPEN_EXCEL_PICKER
        res_excel = self.local_prov.answer_chat(
            message="엑셀 추가해줘",
            document_id="doc_test",
            stage="CAD",
        )
        self.assertEqual(res_excel["action_mode"], "EXECUTE")
        self.assertEqual(res_excel["action_id"], "OPEN_EXCEL_PICKER")

        # 2. '선로 추가해줘' must be circuit mutation -> CONFIRM_REQUIRED
        res_line = self.local_prov.answer_chat(
            message="선로 추가해줘",
            document_id="doc_test",
            stage="CONNECTION_REVIEW",
        )
        self.assertEqual(res_line["action_mode"], "CONFIRM_REQUIRED")
        self.assertIsNone(res_line["action_id"])

        # 3. Simple '추가해줘' without circuit noun does NOT trigger circuit mutation
        res_generic = sanitize_and_validate_agent_response(
            {"reply_ko": "일반 안내", "action_mode": "NONE"},
            user_message="추가해줘",
        )
        self.assertEqual(res_generic["action_mode"], "NONE")

    def test_15_warning_topology_issue_excluded_from_topology_error_count(self):
        """TEST 15: Warning and Info topology issues are NOT counted in topology_error_count."""
        issues = [
            {"id": "iss_1", "severity": "warning", "message": "모선 간격 협소"},
            {"id": "iss_2", "severity": "info", "message": "도면 여백 감지"},
            {"id": "iss_3", "severity": "error", "message": "모선 단락 결선 결함"},
        ]
        res = sanitize_and_validate_agent_response(
            {"reply_ko": "토폴로지 이슈"},
            "상태",
            topology_issues=issues,
        )
        # Only severity == 'error' should be counted
        self.assertEqual(res["evidence_summary"]["topology_error_count"], 1)

    def test_16_block_normalized_to_blocked(self):
        """TEST 16: 'BLOCK' decision is normalized to 'BLOCKED'."""
        raw = {
            "reply_ko": "진행 차단",
            "decision": "BLOCK",
        }
        res = sanitize_and_validate_agent_response(raw, "차단")
        self.assertEqual(res["decision"], "BLOCKED")

    def test_17_staged_api_error_returns_http_500(self):
        """TEST 17: /review/agent_chat and /review/proactive_summary return HTTP 500 JSONResponse on exception."""
        import asyncio
        from review.staged_api import review_agent_chat, review_proactive_summary
        from review.schemas import AgentChatRequest, ProactiveSummaryRequest

        # Mock chat_reviewer.chat to raise an unexpected runtime error
        with patch("review.staged_api.chat_reviewer.chat", side_effect=RuntimeError("Test internal crash")):
            req = AgentChatRequest(
                document_id="test_doc",
                message="안녕하세요",
                stage="OBJECT_REVIEW",
            )
            resp = asyncio.run(review_agent_chat(req))
            self.assertEqual(resp.status_code, 500)
            data = json.loads(resp.body.decode("utf-8"))
            self.assertEqual(data.get("status"), "error")
            self.assertIn("Test internal crash", data.get("message", ""))

        # Mock proactive_summary provider to raise an unexpected error
        with patch("review.staged_api.get_assistant_provider", side_effect=RuntimeError("Test proactive crash")):
            req_pro = ProactiveSummaryRequest(
                document_id="test_doc",
                stage="OBJECT_REVIEW",
            )
            resp_pro = asyncio.run(review_proactive_summary(req_pro))
            self.assertEqual(resp_pro.status_code, 500)
            data_pro = json.loads(resp_pro.body.decode("utf-8"))
            self.assertEqual(data_pro.get("status"), "error")
            self.assertIn("Test proactive crash", data_pro.get("message", ""))


if __name__ == "__main__":
    unittest.main()

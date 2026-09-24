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
    POWERLENS_SYSTEM_KNOWLEDGE,
    VALID_ACTION_MODES,
    VALID_DECISIONS,
    VALID_FOCUS_TARGET_TYPES,
)
from agent.providers import (
    GeminiReviewAssistantProvider,
    LocalReviewAssistantProvider,
    sanitize_and_validate_agent_response,
)


def _valid_final_gate_payload(
    *,
    first_status="DETECTED",
    first_issues=None,
    second_issues=None,
    second_endpoints=None,
):
    nodes = [
        {
            "id": "bus_1",
            "class": "bus",
            "review_status": "CONFIRMED",
            "bbox": [10, 10, 80, 10],
        },
        {
            "id": "gen_1",
            "class": "generator",
            "review_status": "CONFIRMED",
            "bbox": [10, 40, 20, 20],
        },
        {
            "id": "load_1",
            "class": "load",
            "review_status": "CONFIRMED",
            "bbox": [80, 40, 20, 20],
        },
    ]
    lines = [
        {
            "line_id": "line_gen",
            "connected_to": ["bus_1", "gen_1"],
            "path": [[20, 15], [20, 40]],
            "review_status": first_status,
            "validation_issues": first_issues or [],
        },
        {
            "line_id": "line_load",
            "connected_to": second_endpoints or ["bus_1", "load_1"],
            "path": [[80, 15], [90, 40]],
            "review_status": "DETECTED",
            "validation_issues": second_issues or [],
        },
    ]
    return nodes, lines


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

        # Parameter and topology edits are also confirmation-required.
        valid_nodes, valid_lines = _valid_final_gate_payload()
        for message, stage in (
            ("모선 번호를 5로 바꿔줘", "BUS_MAPPING"),
            ("선로 2번을 모선 3번에 연결해줘", "CONNECTION_REVIEW"),
        ):
            gate_context = (
                {
                    "working_nodes": [
                        {
                            "id": "bus_1",
                            "class": "bus",
                            "review_status": "CONFIRMED",
                            "bus_number": 1,
                            "bus_number_status": "VERIFIED",
                        }
                    ]
                }
                if stage == "BUS_MAPPING"
                else {"working_nodes": valid_nodes, "working_lines": valid_lines}
            )
            result = self.local_prov.answer_chat(
                message=message,
                document_id="doc_test",
                stage=stage,
                **gate_context,
            )
            self.assertEqual(result["action_mode"], "CONFIRM_REQUIRED", message)
            self.assertIsNone(result["action_id"], message)

    def test_phase4_voice_commands_route_to_button_actions(self):
        cases = (
            ("도면 불러올래", "HOME", "OPEN_DIAGRAM_PICKER"),
            ("객체 검수 끝났어", "OBJECT_REVIEW", "COMPLETE_CURRENT_STAGE"),
            ("다 봤어", "OBJECT_REVIEW", "COMPLETE_CURRENT_STAGE"),
            ("다음", "OBJECT_REVIEW", "COMPLETE_CURRENT_STAGE"),
            ("모선 다 봤어", "BUS_MAPPING", "COMPLETE_CURRENT_STAGE"),
            ("다음", "BUS_MAPPING", "COMPLETE_CURRENT_STAGE"),
            ("결선 다 봤어", "CONNECTION_REVIEW", "COMPLETE_CURRENT_STAGE"),
            ("결선 끝났어", "CONNECTION_REVIEW", "COMPLETE_CURRENT_STAGE"),
            ("다음", "CONNECTION_REVIEW", "COMPLETE_CURRENT_STAGE"),
            ("엑셀 넣을게", "FINAL", "OPEN_EXCEL_PICKER"),
            ("제원 가져와", "FINAL", "OPEN_EXCEL_PICKER"),
            ("CAD로 넘어가", "FINAL", "HANDOFF_TO_CANVAS"),
            ("캔버스로 이동해줘", "FINAL", "HANDOFF_TO_CANVAS"),
            ("계산해줘", "POWERFLOW_READY", "RUN_POWER_FLOW"),
            ("조류계산 해줘", "POWERFLOW_READY", "RUN_POWER_FLOW"),
            ("결과 보여줘", "POWERFLOW_CONVERGED", "SHOW_POWER_FLOW_RESULTS"),
        )
        clean_nodes, clean_lines = _valid_final_gate_payload()
        clean_bus = [
            {
                "id": "bus_1",
                "class": "bus",
                "review_status": "CONFIRMED",
                "bus_number": 1,
                "bus_number_status": "VERIFIED",
            }
        ]
        for message, stage, expected_action in cases:
            with self.subTest(message=message, stage=stage):
                gate_context = {}
                if stage == "BUS_MAPPING":
                    gate_context["working_nodes"] = clean_bus
                elif stage in ("OBJECT_REVIEW", "CONNECTION_REVIEW"):
                    gate_context["working_nodes"] = clean_nodes
                    gate_context["working_lines"] = clean_lines
                result = self.local_prov.answer_chat(
                    message=message,
                    document_id="doc_test",
                    stage=stage,
                    **gate_context,
                )
                self.assertEqual(result["action_mode"], "EXECUTE", result)
                self.assertEqual(result["action_id"], expected_action, result)

        guidance = self.local_prov.answer_chat(
            message="다음에 무엇을 해야 해?",
            document_id="doc_test",
            stage="OBJECT_REVIEW",
            working_nodes=[{"id": "bus_1", "review_status": "SUSPICIOUS"}],
            missing_candidates=[{"status": "OPEN"}],
        )
        self.assertEqual(guidance["action_mode"], "NONE", guidance)
        self.assertIsNone(guidance["action_id"], guidance)

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

    def test_18_system_knowledge_decision_contract_uses_blocked(self):
        """TEST 18: System knowledge decision contract uses BLOCKED and matches VALID_DECISIONS."""
        self.assertIn("BLOCKED", VALID_DECISIONS)
        self.assertNotIn("BLOCK", VALID_DECISIONS)
        self.assertIn('"decision": "PROCEED" | "HUMAN_CHECK" | "BLOCKED" | "UNKNOWN"', POWERLENS_SYSTEM_KNOWLEDGE)
        self.assertNotIn('"decision": "PROCEED" | "HUMAN_CHECK" | "BLOCK" | "UNKNOWN"', POWERLENS_SYSTEM_KNOWLEDGE)

    def test_19_focus_target_canonical_types_match_system_knowledge(self):
        """TEST 19: Focus target canonical types (OBJECT, LINE, CANDIDATE, ISSUE, UI) match system knowledge."""
        expected_types = {"OBJECT", "LINE", "CANDIDATE", "ISSUE", "UI"}
        self.assertEqual(VALID_FOCUS_TARGET_TYPES, expected_types)
        self.assertIn('"type": "OBJECT" | "LINE" | "CANDIDATE" | "ISSUE" | "UI"', POWERLENS_SYSTEM_KNOWLEDGE)
        self.assertNotIn('"type": "OBJECT" | "BUS" | "LINE" | "UI"', POWERLENS_SYSTEM_KNOWLEDGE)

    def test_20_warning_info_only_topology_issues_yield_zero_error_count(self):
        """TEST 20: When only warning/info topology issues exist, topology_error_count is 0 and decision is PROCEED."""
        issues = [
            {"id": "w1", "severity": "warning", "message": "모선 간격 협소"},
            {"id": "w2", "severity": "WARNING", "message": "모선 레이블 중복 가능성"},
            {"id": "i1", "severity": "info", "message": "도면 여백 안내"},
        ]
        res = sanitize_and_validate_agent_response(
            {"reply_ko": "검토 완료", "decision": "PROCEED"},
            user_message="상태 어때?",
            working_nodes=[{"id": "bus_1", "review_status": "CONFIRMED"}],
            working_lines=[{"line_id": "line_1", "review_status": "CONFIRMED"}],
            missing_candidates=[],
            topology_issues=issues,
        )
        self.assertEqual(res["evidence_summary"]["topology_error_count"], 0)
        self.assertEqual(res["decision"], "PROCEED")

    def test_21_proactive_payload_separates_topology_errors_and_warnings(self):
        """TEST 21: Connection proactive contract is deterministic and warning-safe."""
        prov = GeminiReviewAssistantProvider(
            api_key="test_dummy_key",
            model_name="gemini-3.8-flash",
        )

        issues = [
            {"id": "err_1", "severity": "error", "message": "모선 단락 결선 결함"},
            {"id": "warn_1", "severity": "warning", "message": "단선도 선로 간격 경고"},
            {"id": "info_1", "severity": "info", "message": "도면 정보"},
        ]

        res = prov.generate_proactive_summary(
            document_id="doc_proactive_test",
            stage="CONNECTION_REVIEW",
            working_nodes=[{"id": "b1", "review_status": "NORMAL"}],
            working_lines=[{"line_id": "l1", "review_status": "CONFIRMED"}],
            missing_candidates=[],
            topology_issues=issues,
        )

        self.assertEqual(res["decision"], "HUMAN_CHECK")
        self.assertEqual(res["action_mode"], "GUIDE")
        self.assertIsNone(res["highlight_target"])
        self.assertEqual(res["evidence_summary"]["topology_error_count"], 1)
        self.assertEqual(
            [(target["type"], target["id"]) for target in res["focus_targets"]],
            [("ISSUE", "err_1")],
        )

    def test_22_object_review_proactive_with_suspicious_nodes(self):
        """TEST 22: OBJECT_REVIEW proactive with suspicious nodes returns HUMAN_CHECK, GUIDE, focus_targets, and suppresses legacy object_approve."""
        nodes = [
            {"id": "gen_1", "class": "generator", "review_status": "NORMAL"},
            {"id": "gen_susp", "class": "generator", "review_status": "SUSPICIOUS", "review_reasons": ["신뢰도 0.65로 낮음"]},
        ]
        res = self.local_prov.generate_proactive_summary(
            document_id="doc_obj_test",
            stage="OBJECT_REVIEW",
            working_nodes=nodes,
            working_lines=[],
            missing_candidates=[],
            topology_issues=[],
        )
        self.assertEqual(res["decision"], "HUMAN_CHECK")
        self.assertEqual(res["action_mode"], "GUIDE")
        self.assertIsNone(res["highlight_target"])  # legacy object_approve highlight is NOT used
        self.assertNotEqual(res["highlight_target"], "object_approve")
        focus_ids = [f["id"] for f in res["focus_targets"]]
        self.assertIn("gen_susp", focus_ids)
        self.assertNotIn("gen_1", focus_ids)

        # Also verify sanitize_and_validate_agent_response suppresses object_approve in OBJECT_REVIEW
        raw_llm = {
            "reply_ko": "검토하세요",
            "decision": "HUMAN_CHECK",
            "action_mode": "GUIDE",
            "highlight_target": "object_approve",
            "focus_targets": [{"type": "OBJECT", "id": "gen_susp"}],
        }
        sanitized = sanitize_and_validate_agent_response(
            raw_llm,
            user_message="",
            working_nodes=nodes,
            working_lines=[],
            missing_candidates=[],
            topology_issues=[],
            stage="OBJECT_REVIEW",
        )
        self.assertIsNone(sanitized["highlight_target"])

    def test_23_object_review_proactive_clean_nodes(self):
        """TEST 23: OBJECT_REVIEW proactive with clean nodes returns PROCEED, NONE, and no fabricated targets."""
        nodes = [
            {"id": "gen_1", "class": "generator", "review_status": "NORMAL"},
            {"id": "bus_1", "class": "bus", "review_status": "CONFIRMED"},
        ]
        res = self.local_prov.generate_proactive_summary(
            document_id="doc_obj_clean",
            stage="OBJECT_REVIEW",
            working_nodes=nodes,
            working_lines=[],
            missing_candidates=[],
            topology_issues=[],
        )
        self.assertEqual(res["decision"], "PROCEED")
        self.assertEqual(res["action_mode"], "NONE")
        self.assertEqual(len(res["focus_targets"]), 0)
        self.assertIsNone(res["highlight_target"])

    def test_24_bus_mapping_proactive_with_uncertain_bus(self):
        """BACKEND TEST 1: BUS_MAPPING + uncertain Bus -> HUMAN_CHECK, GUIDE, focus target type OBJECT, actual Bus ID."""
        nodes = [
            {"id": "bus_1", "class": "bus", "bus_number": 1, "bus_number_status": "VERIFIED"},
            {"id": "bus_2", "class": "bus", "bus_number": None, "bus_number_status": "UNCERTAIN"},
        ]
        res = self.local_prov.generate_proactive_summary(
            document_id="doc_bus_test",
            stage="BUS_MAPPING",
            working_nodes=nodes,
            working_lines=[],
            missing_candidates=[],
            topology_issues=[],
        )
        self.assertEqual(res["decision"], "HUMAN_CHECK")
        self.assertEqual(res["action_mode"], "GUIDE")
        self.assertIsNone(res["highlight_target"])  # bus_input button highlight is NOT used
        self.assertEqual(len(res["focus_targets"]), 1)
        self.assertEqual(res["focus_targets"][0]["type"], "OBJECT")
        self.assertEqual(res["focus_targets"][0]["id"], "bus_2")

    def test_25_focus_target_type_bus_normalized_to_object(self):
        """BACKEND TEST 2: focus target type BUS does not remain in canonical output (normalized to OBJECT)."""
        raw = {
            "reply_ko": "모선 확인",
            "decision": "HUMAN_CHECK",
            "intent": "TEST_INTENT",
            "focus_targets": [
                {"type": "BUS", "id": "bus_1"},
            ],
        }
        res = sanitize_and_validate_agent_response(
            raw,
            user_message="모선 확인",
            working_nodes=[{"id": "bus_1", "class": "bus", "review_status": "NORMAL"}],
            working_lines=[],
            missing_candidates=[],
            topology_issues=[],
            stage="BUS_MAPPING",
        )
        for t in res["focus_targets"]:
            self.assertNotEqual(t["type"], "BUS")
            self.assertEqual(t["type"], "OBJECT")
            self.assertEqual(t["id"], "bus_1")

    def test_26_bus_mapping_clean_bus_proactive(self):
        """BACKEND TEST 3: clean Bus -> PROCEED, NONE, no fabricated target."""
        nodes = [
            {"id": "bus_1", "class": "bus", "bus_number": 1, "bus_number_status": "VERIFIED"},
            {"id": "bus_2", "class": "bus", "bus_number": 2, "bus_number_status": "VERIFIED"},
        ]
        res = self.local_prov.generate_proactive_summary(
            document_id="doc_bus_clean",
            stage="BUS_MAPPING",
            working_nodes=nodes,
            working_lines=[],
            missing_candidates=[],
            topology_issues=[],
        )
        self.assertEqual(res["decision"], "PROCEED")
        self.assertEqual(res["action_mode"], "NONE")
        self.assertEqual(len(res["focus_targets"]), 0)
        self.assertIsNone(res["highlight_target"])

    def test_27_bus_gate_duplicate_bus_numbers(self):
        """BACKEND TEST 4: duplicate Bus 번호 -> 두 Bus 모두 issue 대상."""
        import asyncio
        from review.staged_api import review_verify_bus_gate
        from review.schemas import VerifyBusGateRequest

        nodes = [
            {"id": "bus_1", "class": "bus", "bus_number": 5, "bus_number_status": "VERIFIED"},
            {"id": "bus_2", "class": "bus", "bus_number": 5, "bus_number_status": "VERIFIED"},
        ]
        req = VerifyBusGateRequest(document_id="doc_dup", working_nodes=nodes)
        res = asyncio.run(review_verify_bus_gate(req))

        self.assertEqual(res["gate_status"], "BLOCKED")
        self.assertIn("bus_1", res["focus_node_ids"])
        self.assertIn("bus_2", res["focus_node_ids"])
        self.assertTrue(any("중복" in b for b in res["blockers"]))

    def test_28_bus_gate_null_number(self):
        """BACKEND TEST 5: 번호 null -> issue."""
        import asyncio
        from review.staged_api import review_verify_bus_gate
        from review.schemas import VerifyBusGateRequest

        nodes = [
            {"id": "bus_1", "class": "bus", "bus_number": 1, "bus_number_status": "VERIFIED"},
            {"id": "bus_2", "class": "bus", "bus_number": None, "bus_number_status": "UNCERTAIN"},
        ]
        req = VerifyBusGateRequest(document_id="doc_null", working_nodes=nodes)
        res = asyncio.run(review_verify_bus_gate(req))

        self.assertEqual(res["gate_status"], "BLOCKED")
        self.assertIn("bus_2", res["focus_node_ids"])
        self.assertTrue(any("미지정" in b for b in res["blockers"]))

    def test_29_bus_gate_uncertain_status_with_number(self):
        """BACKEND TEST 6: bus_number_status UNCERTAIN인데 번호 자체는 존재 -> Gate BLOCKED, blocker 설명 존재."""
        import asyncio
        from review.staged_api import review_verify_bus_gate
        from review.schemas import VerifyBusGateRequest

        nodes = [
            {"id": "bus_1", "class": "bus", "bus_number": 1, "bus_number_status": "VERIFIED"},
            {"id": "bus_2", "class": "bus", "bus_number": 2, "bus_number_status": "UNCERTAIN"},
        ]
        req = VerifyBusGateRequest(document_id="doc_unc", working_nodes=nodes)
        res = asyncio.run(review_verify_bus_gate(req))

        self.assertEqual(res["gate_status"], "BLOCKED")
        self.assertIn("bus_2", res["focus_node_ids"])
        self.assertTrue(len(res["blockers"]) > 0)
        self.assertTrue(any("UNCERTAIN" in b or "불확실" in b for b in res["blockers"]))

    def test_30_bus_gate_non_contiguous_valid_ids(self):
        """BACKEND TEST 7: non-contiguous valid IDs: Bus 1, Bus 5, Bus 20이 모두 unique/verified라면 expected range가 별도 제공되지 않은 경우 '2~4가 없다'는 이유로 막지 않는다."""
        import asyncio
        from review.staged_api import review_verify_bus_gate
        from review.schemas import VerifyBusGateRequest

        nodes = [
            {"id": "bus_1", "class": "bus", "bus_number": 1, "bus_number_status": "VERIFIED"},
            {"id": "bus_2", "class": "bus", "bus_number": 5, "bus_number_status": "VERIFIED"},
            {"id": "bus_3", "class": "bus", "bus_number": 20, "bus_number_status": "VERIFIED"},
        ]
        req = VerifyBusGateRequest(document_id="doc_non_contig", working_nodes=nodes)
        res = asyncio.run(review_verify_bus_gate(req))

        self.assertEqual(res["gate_status"], "BUS_VERIFIED")
        self.assertEqual(len(res["blockers"]), 0)
        self.assertEqual(len(res["focus_node_ids"]), 0)

    def test_31_no_hardcoded_bus_confidence_099(self):
        """BACKEND TEST 8: hardcoded bus_confidence 0.99 없음."""
        import inspect
        import core.bus_number_linker as linker_mod

        src = inspect.getsource(linker_mod)
        self.assertNotIn("bus_confidence = 0.99", src)
        self.assertNotIn("0.99", src)

    def test_32_rejected_bus_is_excluded_from_proactive_and_gate(self):
        """TEST X: rejected + uncertain Bus is excluded from active Bus state."""
        import asyncio
        from review.schemas import VerifyBusGateRequest
        from review.staged_api import review_verify_bus_gate

        nodes = [
            {"id": "bus_active", "class": "bus", "bus_number": 5, "bus_number_status": "VERIFIED"},
            {"id": "bus_rejected", "class": "bus", "bus_number": None, "bus_number_status": "UNCERTAIN", "review_status": "REJECTED"},
        ]
        proactive = self.local_prov.generate_proactive_summary(
            document_id="doc_rejected_bus",
            stage="BUS_MAPPING",
            working_nodes=nodes,
        )
        gate = asyncio.run(
            review_verify_bus_gate(
                VerifyBusGateRequest(document_id="doc_rejected_bus", working_nodes=nodes)
            )
        )

        self.assertEqual(proactive["bus_summary"]["total_buses"], 1)
        self.assertEqual(proactive["bus_summary"]["issue_buses"], 0)
        self.assertEqual(proactive["focus_targets"], [])
        self.assertEqual(gate["gate_status"], "BUS_VERIFIED")
        self.assertEqual(gate["bus_summary"]["total_buses"], 1)

    def test_33_active_duplicate_reason_is_consistent_across_paths(self):
        """TEST Y: active DUPLICATE_BUS_NUMBER_* blocks proactive, chat, and Gate."""
        import asyncio
        from review.schemas import VerifyBusGateRequest
        from review.staged_api import review_verify_bus_gate

        nodes = [
            {"id": "bus_unique", "class": "bus", "bus_number": 1, "bus_number_status": "VERIFIED"},
            {
                "id": "bus_reason",
                "class": "bus",
                "bus_number": 5,
                "bus_number_status": "VERIFIED",
                "bus_number_reasons": ["DUPLICATE_BUS_NUMBER_5"],
            },
        ]
        proactive = self.local_prov.generate_proactive_summary(
            document_id="doc_active_reason",
            stage="BUS_MAPPING",
            working_nodes=nodes,
        )
        chat = self.local_prov.answer_chat(
            message="다음에 뭐 해?",
            document_id="doc_active_reason",
            stage="BUS_MAPPING",
            working_nodes=nodes,
        )
        gate = asyncio.run(
            review_verify_bus_gate(
                VerifyBusGateRequest(document_id="doc_active_reason", working_nodes=nodes)
            )
        )

        self.assertEqual(proactive["decision"], "HUMAN_CHECK")
        self.assertEqual(proactive["bus_summary"]["issue_buses"], 1)
        self.assertEqual(proactive["focus_targets"][0]["id"], "bus_reason")
        self.assertEqual(chat["decision"], "HUMAN_CHECK")
        self.assertNotIn("모든 모선 번호가 확인되었습니다", chat["reply_ko"])
        self.assertEqual(gate["gate_status"], "BLOCKED")
        self.assertIn("bus_reason", gate["focus_node_ids"])

    def test_34_non_contiguous_clean_buses_remain_clean_in_proactive(self):
        """TEST backend contract: 1, 5, 20 are valid when unique."""
        nodes = [
            {"id": "bus_1", "class": "bus", "bus_number": 1, "bus_number_status": "VERIFIED"},
            {"id": "bus_5", "class": "bus", "bus_number": 5, "bus_number_status": "VERIFIED"},
            {"id": "bus_20", "class": "bus", "bus_number": 20, "bus_number_status": "VERIFIED"},
        ]
        proactive = self.local_prov.generate_proactive_summary(
            document_id="doc_non_contiguous_proactive",
            stage="BUS_MAPPING",
            working_nodes=nodes,
        )

        self.assertEqual(proactive["decision"], "PROCEED")
        self.assertEqual(proactive["bus_summary"]["total_buses"], 3)
        self.assertEqual(proactive["bus_summary"]["issue_buses"], 0)
        self.assertEqual(proactive["focus_targets"], [])

    def test_35_zero_active_bus_blocks_proactive_chat_and_sanitizer(self):
        """TEST AA/AB: zero active Bus is BLOCKED everywhere, never clean/PROCEED."""
        nodes = [{"id": "gen_1", "class": "generator", "review_status": "CONFIRMED"}]

        proactive = self.local_prov.generate_proactive_summary(
            document_id="doc_zero_bus",
            stage="BUS_MAPPING",
            working_nodes=nodes,
        )
        self.assertEqual(proactive["decision"], "BLOCKED")
        self.assertEqual(proactive["focus_targets"], [])
        self.assertEqual(proactive["bus_summary"]["total_buses"], 0)
        self.assertIn("유효한 모선", proactive["reply_ko"])
        self.assertNotIn("모선 번호 확인이 완료", proactive["reply_ko"])

        chat = self.local_prov.answer_chat(
            message="다음에 뭐 해?",
            document_id="doc_zero_bus",
            stage="BUS_MAPPING_REVIEW",
            working_nodes=nodes,
        )
        self.assertEqual(chat["decision"], "BLOCKED")
        self.assertIn("유효한 모선", chat["reply_ko"])
        self.assertNotIn("확인 필요: **0개**", chat["reply_ko"])

        sanitized = sanitize_and_validate_agent_response(
            {
                "reply_ko": "모든 모선 번호가 확인되었습니다.",
                "decision": "PROCEED",
                "action_mode": "NONE",
                "focus_targets": [],
            },
            stage="BUS_MAPPING",
            working_nodes=nodes,
        )
        self.assertEqual(sanitized["decision"], "BLOCKED")
        self.assertEqual(sanitized["focus_targets"], [])
        self.assertIn("유효한 모선", sanitized["reply_ko"])

    def test_36_zero_active_bus_gate_remains_blocked(self):
        """TEST AC: the existing Bus Gate has the same zero-Bus blocker meaning."""
        import asyncio
        from review.schemas import VerifyBusGateRequest
        from review.staged_api import review_verify_bus_gate

        gate = asyncio.run(
            review_verify_bus_gate(
                VerifyBusGateRequest(document_id="doc_zero_bus_gate", working_nodes=[])
            )
        )

        self.assertEqual(gate["gate_status"], "BLOCKED")
        self.assertEqual(gate["focus_node_ids"], [])
        self.assertIn("유효한 모선", gate["message"])

    def test_37_connection_v2_exception_first_backend_contract(self):
        """Connection A~X core predicates: clean, ambiguous, error, warning, zero-line, and focus safety."""
        clean = self.local_prov.generate_proactive_summary(
            document_id="doc_conn_clean",
            stage="CONNECTION_REVIEW",
            working_lines=[{"line_id": "l_clean", "review_status": "DETECTED"}],
        )
        self.assertEqual(clean["decision"], "PROCEED")
        self.assertEqual(clean["action_mode"], "NONE")
        self.assertIsNone(clean["highlight_target"])
        self.assertEqual(clean["focus_targets"], [])

        ambiguous = self.local_prov.generate_proactive_summary(
            document_id="doc_conn_ambiguous",
            stage="CONNECTION_REVIEW",
            working_lines=[{"line_id": "l_amb", "review_status": "AMBIGUOUS"}],
        )
        self.assertEqual(ambiguous["decision"], "HUMAN_CHECK")
        self.assertEqual(ambiguous["action_mode"], "GUIDE")
        self.assertEqual(ambiguous["focus_targets"][0]["id"], "l_amb")
        self.assertIsNone(ambiguous["highlight_target"])

        critical = self.local_prov.generate_proactive_summary(
            document_id="doc_conn_error",
            stage="CONNECTION_REVIEW",
            working_lines=[
                {
                    "line_id": "l_error",
                    "review_status": "DETECTED",
                    "validation_issues": [
                        {"id": "line_issue_1", "severity": "error", "message": "끝점 오류"}
                    ],
                }
            ],
        )
        self.assertEqual(critical["decision"], "HUMAN_CHECK")
        self.assertEqual(critical["focus_targets"][0]["id"], "l_error")

        warning_only = self.local_prov.generate_proactive_summary(
            document_id="doc_conn_warning",
            stage="CONNECTION_REVIEW",
            working_lines=[{"line_id": "l_warning", "review_status": "DETECTED"}],
            topology_issues=[{"id": "warn_1", "severity": "warning", "message": "간격 안내"}],
        )
        self.assertEqual(warning_only["decision"], "PROCEED")
        self.assertEqual(warning_only["evidence_summary"]["topology_error_count"], 0)

        no_active = self.local_prov.generate_proactive_summary(
            document_id="doc_conn_empty",
            stage="CONNECTION_REVIEW",
            working_lines=[{"line_id": "l_rejected", "review_status": "REJECTED"}],
        )
        self.assertEqual(no_active["decision"], "BLOCKED")
        self.assertEqual(no_active["action_mode"], "GUIDE")
        self.assertIn("유효한 결선", no_active["reply_ko"])
        self.assertEqual(no_active["focus_targets"], [])

        fabricated = sanitize_and_validate_agent_response(
            {
                "reply_ko": "가상 포커스",
                "decision": "HUMAN_CHECK",
                "action_mode": "GUIDE",
                "focus_targets": [
                    {"type": "LINE", "id": "line_fake"},
                    {"type": "ISSUE", "id": "issue_fake"},
                ],
            },
            stage="CONNECTION_REVIEW",
            working_lines=[{"line_id": "l_real", "review_status": "AMBIGUOUS"}],
        )
        self.assertEqual([target["id"] for target in fabricated["focus_targets"]], ["l_real"])

        mutation = self.local_prov.answer_chat(
            message="선로 추가해줘",
            document_id="doc_conn_mutation",
            stage="CONNECTION_REVIEW",
            working_lines=[{"line_id": "l_real", "review_status": "DETECTED"}],
        )
        self.assertEqual(mutation["action_mode"], "CONFIRM_REQUIRED")
        self.assertIsNone(mutation["action_id"])

    def test_38_connection_final_gate_rejects_zero_active_lines(self):
        """Authoritative final gate blocks a valid node set when every line is rejected."""
        import asyncio
        from review.schemas import VerifyFinalGateRequest
        from review.staged_api import review_verify_final_gate

        fake_session = MagicMock(width=100, height=100)
        request = VerifyFinalGateRequest(
            document_id="doc_conn_gate_empty",
            working_nodes=[
                {
                    "id": "bus_1",
                    "class": "bus",
                    "review_status": "CONFIRMED",
                    "bbox": [10, 10, 20, 20],
                }
            ],
            working_lines=[{"line_id": "l_rejected", "review_status": "REJECTED"}],
        )
        with patch("review.staged_api.session_store.get_session", return_value=fake_session):
            result = asyncio.run(review_verify_final_gate(request))

        self.assertEqual(result["gate_status"], "BLOCKED")
        self.assertIn("유효한 결선", result["message"])

    def test_39_connection_final_gate_blocks_raw_line_error(self):
        """TEST AF: raw line severity=error blocks before graph normalization."""
        import asyncio
        from review.schemas import VerifyFinalGateRequest
        from review.staged_api import review_verify_final_gate

        nodes, lines = _valid_final_gate_payload(
            first_issues=[
                {
                    "id": "shared_line_error",
                    "code": "EXPLICIT_LINE_ERROR",
                    "severity": "error",
                    "message": "명시적 선로 검증 오류",
                }
            ]
        )
        request = VerifyFinalGateRequest(
            document_id="doc_conn_gate_line_error",
            working_nodes=nodes,
            working_lines=lines,
        )
        with patch(
            "review.staged_api.session_store.get_session",
            return_value=MagicMock(width=100, height=100),
        ):
            result = asyncio.run(review_verify_final_gate(request))

        self.assertEqual(result["gate_status"], "BLOCKED")
        self.assertIn("전기적 연결 오류", result["message"])

    def test_40_connection_final_gate_warning_info_do_not_block(self):
        """TEST AG: warning/info line evidence alone still reaches VERIFIED."""
        import asyncio
        from review.schemas import VerifyFinalGateRequest
        from review.staged_api import review_verify_final_gate

        nodes, lines = _valid_final_gate_payload(
            first_issues=[{"id": "warn", "severity": "warning", "message": "간격 안내"}],
            second_issues=[{"id": "info", "severity": "info", "message": "추적 정보"}],
        )
        request = VerifyFinalGateRequest(
            document_id="doc_conn_gate_warning_info",
            working_nodes=nodes,
            working_lines=lines,
        )
        with patch(
            "review.staged_api.session_store.get_session",
            return_value=MagicMock(width=100, height=100),
        ):
            result = asyncio.run(review_verify_final_gate(request))

        self.assertEqual(result["gate_status"], "VERIFIED")

    def test_41_connection_final_gate_preserves_ambiguous_and_graph_blockers(self):
        """TEST AH: AMBIGUOUS and later validate_graph errors remain blockers."""
        import asyncio
        from review.schemas import VerifyFinalGateRequest
        from review.staged_api import review_verify_final_gate

        nodes, ambiguous_lines = _valid_final_gate_payload(first_status="AMBIGUOUS")
        ambiguous_request = VerifyFinalGateRequest(
            document_id="doc_conn_gate_ambiguous",
            working_nodes=nodes,
            working_lines=ambiguous_lines,
        )
        nodes2, invalid_graph_lines = _valid_final_gate_payload(
            second_endpoints=["bus_1", "missing_node"]
        )
        graph_request = VerifyFinalGateRequest(
            document_id="doc_conn_gate_graph_error",
            working_nodes=nodes2,
            working_lines=invalid_graph_lines,
        )
        with patch(
            "review.staged_api.session_store.get_session",
            return_value=MagicMock(width=100, height=100),
        ):
            ambiguous_result = asyncio.run(
                review_verify_final_gate(ambiguous_request)
            )
            graph_result = asyncio.run(review_verify_final_gate(graph_request))

        self.assertEqual(ambiguous_result["gate_status"], "BLOCKED")
        self.assertIn("불확실", ambiguous_result["message"])
        self.assertEqual(graph_result["gate_status"], "BLOCKED")
        self.assertGreater(graph_result["critical_issue_count"], 0)

    def test_42_connection_error_count_deduplicates_line_and_topology_evidence(self):
        """The same critical issue in both payloads counts once."""
        shared = {
            "id": "shared_error",
            "code": "EXPLICIT_LINE_ERROR",
            "severity": "error",
            "message": "동일한 결선 오류",
        }
        result = self.local_prov.generate_proactive_summary(
            document_id="doc_conn_duplicate_error",
            stage="CONNECTION_REVIEW",
            working_lines=[
                {
                    "line_id": "line_shared",
                    "review_status": "DETECTED",
                    "validation_issues": [shared],
                }
            ],
            topology_issues=[shared],
        )

        self.assertEqual(result["evidence_summary"]["topology_error_count"], 1)
        self.assertIn("전기 오류: **1건**", result["summary_text"])

    def test_43_connection_final_gate_blocks_explicit_unresolved_crossing(self):
        """Explicit crossing payloads block; no crossing detector is inferred."""
        import asyncio
        from review.schemas import VerifyFinalGateRequest
        from review.staged_api import review_verify_final_gate

        nodes, lines = _valid_final_gate_payload()
        lines[0]["evidence"] = {"crossing_candidate": True}
        request = VerifyFinalGateRequest(
            document_id="doc_conn_gate_crossing",
            working_nodes=nodes,
            working_lines=lines,
        )
        with patch(
            "review.staged_api.session_store.get_session",
            return_value=MagicMock(width=100, height=100),
        ):
            result = asyncio.run(review_verify_final_gate(request))

        self.assertEqual(result["gate_status"], "BLOCKED")
        self.assertIn("교차", result["message"])


if __name__ == "__main__":
    unittest.main()

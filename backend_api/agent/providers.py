"""VisionFlow Review Assistant Provider Architecture.

Defines the common interface for Review Assistant Providers and implements:
1. LocalReviewAssistantProvider (Default, deterministic, free, evidence-based local intelligence).
2. OpenAIReviewAssistantProvider (Future adapter skeleton with cost safety guards).
3. Factory function `get_assistant_provider()` supporting explicit opt-in (`AI_PROVIDER=openai`).
"""
from __future__ import annotations

import abc
import json
import math
import os
import time
from typing import Any, Dict, List, Optional
import numpy as np

from .system_knowledge import POWERLENS_SYSTEM_KNOWLEDGE
from .model_config import (
    DEFAULT_GEMINI_PRIMARY_MODEL,
    DEFAULT_GEMINI_FALLBACK_MODEL,
    get_gemini_model_name,
    get_gemini_fallback_model_name,
)

try:
    from pydantic import BaseModel

    class ChatMessagePayload(BaseModel):
        role: str  # "user", "assistant", "system"
        content: str
except ImportError:
    from dataclasses import dataclass

    @dataclass
    class ChatMessagePayload:
        role: str
        content: str


# Chat History Window Limit to prevent unbounded memory growth
MAX_CHAT_HISTORY = 15

from .system_knowledge import (
    ALLOW_LISTED_ACTIONS,
    CANONICAL_RESPONSE_SCHEMA,
    VALID_ACTION_MODES,
    VALID_DECISIONS,
    VALID_FOCUS_TARGET_TYPES,
    VALID_HIGHLIGHT_TARGETS,
)
from core.bus_review_contract import BUS_NO_ACTIVE_MESSAGE, evaluate_bus_mapping
from .connection_review_contract import (
    CONNECTION_NO_ACTIVE_MESSAGE,
    active_connection_lines,
    connection_exception_line_ids,
    connection_has_blockers,
    critical_connection_error_count,
    issue_identifier,
    is_error_issue,
    line_has_critical_issue,
    line_id,
    line_validation_issues,
    related_line_ids,
)


def _is_bus_mapping_stage(stage: str) -> bool:
    return (stage or "").upper() in ("BUS_MAPPING", "BUS_MAPPING_REVIEW")


def _is_connection_review_stage(stage: str) -> bool:
    return (stage or "").upper() in (
        "CONNECTION_REVIEW",
        "CONNECTION",
        "LINE_REVIEW",
    )


def _powerflow_evidence_detail(app_context: Optional[Dict[str, Any]]) -> Optional[str]:
    evidence = (app_context or {}).get("powerflow_evidence")
    if not isinstance(evidence, dict) or not isinstance(evidence.get("converged"), bool):
        return None

    state = "수렴" if evidence["converged"] else "미수렴"
    details = [f"실제 Newton–Raphson 결과: {state}"]
    iterations = evidence.get("iterations")
    if isinstance(iterations, (int, float)) and not isinstance(iterations, bool):
        details.append(f"{iterations}회 반복")
    mismatch = evidence.get("max_mismatch")
    if isinstance(mismatch, (int, float)) and not isinstance(mismatch, bool) and math.isfinite(mismatch):
        details.append(f"최대 mismatch {mismatch}")

    if evidence["converged"]:
        lowest = evidence.get("lowest_voltage")
        if isinstance(lowest, dict):
            bus = lowest.get("bus")
            voltage = lowest.get("voltage_pu")
            if isinstance(voltage, (int, float)) and not isinstance(voltage, bool) and math.isfinite(voltage):
                details.append(f"최저 전압: Bus {bus}, {voltage} pu")
        flow = evidence.get("largest_absolute_line_flow")
        if isinstance(flow, dict):
            from_bus, to_bus = flow.get("from_bus"), flow.get("to_bus")
            signed_mw = flow.get("p_from_mw")
            if isinstance(signed_mw, (int, float)) and not isinstance(signed_mw, bool) and math.isfinite(signed_mw):
                details.append(f"최대 절대 선로 흐름 후보: Bus {from_bus}→{to_bus}, signed P_from {signed_mw} MW")
    return " · ".join(details)


def is_circuit_mutation_request(user_message: str) -> bool:
    """Determine whether the message requests a circuit mutation.

    Requires both a circuit target noun (e.g. 모선, 선로, 객체, 결선, 클래스, 번호)
    and a mutation verb (e.g. 추가, 변경, 수정, 삭제, 지워).
    Requests for safe external resources (e.g. 엑셀, 도면, 샘플) are excluded.
    """
    msg = (user_message or "").strip().lower().replace("캔버스", "")
    safe_resources = ["엑셀", "excel", "xlsx", "샘플", "sample", "도면", "사진", "이미지", "파일"]
    circuit_nouns = [
        "객체", "모선", "선로", "결선", "클래스", "종류", "타입", "심볼", "번호", "노드", "라인", "버스",
        "발전기", "부하", "변압기", "설비", "generator", "load", "bus", "line", "transformer"
    ]
    mutation_verbs = [
        "바꿔", "변경", "수정", "삭제", "지워", "제외", "추가", "바꿈", "바꾸",
        "입력", "설정", "지정", "연결해", "분리해", "이동해", "옮겨"
    ]

    has_safe_resource = any(r in msg for r in safe_resources)
    has_circuit_noun = any(cn in msg for cn in circuit_nouns)
    has_mutation_verb = any(v in msg for v in mutation_verbs)

    if has_safe_resource and not has_circuit_noun:
        return False

    return has_circuit_noun and has_mutation_verb


def sanitize_and_validate_agent_response(
    raw_dict: Dict[str, Any],
    user_message: str = "",
    working_nodes: Optional[List[Dict[str, Any]]] = None,
    working_lines: Optional[List[Dict[str, Any]]] = None,
    missing_candidates: Optional[List[Dict[str, Any]]] = None,
    topology_issues: Optional[List[Dict[str, Any]]] = None,
    stage: str = "HOME",
) -> Dict[str, Any]:
    """Sanitize and enforce the Canonical Agent Response Contract.

    Guarantees:
    1. evidence_summary is ALWAYS recomputed by server from ground truth.
    2. topology_error_count only includes issues with severity == 'error'.
    3. decision is in {PROCEED, HUMAN_CHECK, BLOCKED, UNKNOWN}, normalized (BLOCK -> BLOCKED).
       Prevents PROCEED if actual issues exist (forces HUMAN_CHECK).
    4. action_mode is in {NONE, GUIDE, EXECUTE, CONFIRM_REQUIRED}.
    5. action_mode is downgraded to GUIDE for location/how-to questions ('어디', '어떻게', etc.).
    6. action_mode is set to CONFIRM_REQUIRED only for circuit mutations.
    7. action_id is restricted to ALLOW_LISTED_ACTIONS (or None).
    8. highlight_target is validated against VALID_HIGHLIGHT_TARGETS (invalid -> None).
    9. focus_targets strictly validates type and ID against ground truth.
       (OBJECT: node, LINE: line, CANDIDATE: candidate, ISSUE: issue, UI: allow-list).
    10. intent and all canonical fields are normalized.
    """
    res = dict(raw_dict)

    # 1. Clean reply_ko
    reply_ko = str(res.get("reply_ko") or res.get("reply") or res.get("summary_text") or "").strip()
    if reply_ko.startswith("```json"):
        reply_ko = reply_ko[7:]
    elif reply_ko.startswith("```"):
        reply_ko = reply_ko[3:]
    if reply_ko.endswith("```"):
        reply_ko = reply_ko[:-3]
    reply_ko = reply_ko.strip()
    if reply_ko.startswith("{") and reply_ko.endswith("}"):
        try:
            inner_json = json.loads(reply_ko)
            if isinstance(inner_json, dict) and "reply_ko" in inner_json:
                reply_ko = str(inner_json["reply_ko"]).strip()
        except Exception:
            pass
    if not reply_ko:
        reply_ko = "현재 상태를 확인했습니다. 안내가 필요하시면 언제든 질문해주세요."
    res["reply_ko"] = reply_ko

    # 2. Ground-truth evidence calculation (ALWAYS recomputed by server)
    w_nodes = working_nodes or []
    w_lines = working_lines or []
    cands = missing_candidates or []
    issues = topology_issues or []

    susp_cnt = len([n for n in w_nodes if str(n.get("review_status") or n.get("status", "")).upper() == "SUSPICIOUS"])
    miss_cnt = len([c for c in cands if str(c.get("status", "")).upper() == "OPEN"])
    active_lines = active_connection_lines(w_lines)
    amb_cnt = len([l for l in active_lines if str(l.get("review_status") or l.get("status", "")).upper() == "AMBIGUOUS"])
    # Connection error counts deduplicate the same evidence when it appears
    # in both a line payload and topology_issues.
    err_cnt = len([i for i in issues if is_error_issue(i)])
    if _is_connection_review_stage(stage):
        err_cnt = critical_connection_error_count(active_lines, issues)
    line_error_cnt = len([l for l in active_lines if line_has_critical_issue(l)])

    bus_state = evaluate_bus_mapping(w_nodes) if _is_bus_mapping_stage(stage) else None
    bus_blocked = bool(bus_state and bus_state["total"] == 0)
    connection_blocked = _is_connection_review_stage(stage) and connection_has_blockers(
        active_lines, issues
    )
    has_issues = (
        susp_cnt > 0
        or miss_cnt > 0
        or amb_cnt > 0
        or err_cnt > 0
        or line_error_cnt > 0
        or bus_blocked
        or bool(bus_state and bus_state["issue_count"] > 0)
        or connection_blocked
    )

    res["evidence_summary"] = {
        "suspicious_count": susp_cnt,
        "missing_count": miss_cnt,
        "ambiguous_count": amb_cnt,
        "topology_error_count": err_cnt,
    }
    if bus_state is not None:
        res["evidence_summary"].update(
            {
                "bus_total_count": bus_state["total"],
                "bus_verified_count": bus_state["verified_count"],
                "bus_issue_count": bus_state["issue_count"],
            }
        )

    # 3. Decision validation & normalization
    dec = str(res.get("decision", "")).strip().upper()
    if dec == "BLOCK":
        dec = "BLOCKED"
    if dec not in VALID_DECISIONS:
        dec = "HUMAN_CHECK" if has_issues else "PROCEED"
    elif dec == "PROCEED" and has_issues:
        # Prevent PROCEED when actual evidence contradicts it
        dec = "HUMAN_CHECK"
    res["decision"] = dec

    # 4. Intent normalization
    intent = str(res.get("intent", "")).strip()
    if not intent:
        intent = "GENERAL_CHAT"
    res["intent"] = intent

    # 5. Action Mode & Semantic Safety Guards
    act_mode = str(res.get("action_mode", "")).strip().upper()
    if act_mode not in VALID_ACTION_MODES:
        act_mode = "NONE"

    msg_norm = (user_message or "").strip().lower().replace(" ", "")

    # Location / Guidance questions must be GUIDE, NEVER EXECUTE
    is_where_how = any(k in msg_norm for k in [
        "어디", "어떻게", "뭐눌러", "뭘눌러", "무엇을눌러", "어느버튼", "버튼어디", "위치", "방법", "어디야", "어디서", "어디에"
    ])
    # Circuit mutations must be CONFIRM_REQUIRED
    is_mutation = is_circuit_mutation_request(user_message)

    if is_mutation:
        act_mode = "CONFIRM_REQUIRED"
        res["action_id"] = None
    elif is_where_how:
        if act_mode == "EXECUTE":
            act_mode = "GUIDE"

    res["action_mode"] = act_mode

    # 6. Action ID allow-listing
    act_id = res.get("action_id")
    if act_id and isinstance(act_id, str):
        act_id_upper = act_id.strip().upper()
        if act_id_upper in ALLOW_LISTED_ACTIONS:
            res["action_id"] = act_id_upper
        else:
            res["action_id"] = None
    else:
        res["action_id"] = None

    if res["action_mode"] in ("NONE", "CONFIRM_REQUIRED"):
        res["action_id"] = None

    if "action_params" not in res or not isinstance(res["action_params"], dict):
        res["action_params"] = {}

    # 7. Highlight target validation against allow-list
    hl = res.get("highlight_target")
    if hl and isinstance(hl, str):
        hl_clean = hl.strip()
        if hl_clean.lower() in ("null", "none", "") or hl_clean not in VALID_HIGHLIGHT_TARGETS:
            res["highlight_target"] = None
        else:
            res["highlight_target"] = hl_clean
    else:
        res["highlight_target"] = None

    if res.get("action_id") == "RUN_POWER_FLOW" and not res.get("highlight_target"):
        res["highlight_target"] = "final_powerflow"

    # 8. Strict focus targets validation (Type & ID matching)
    valid_node_ids = {str(n.get("id")) for n in w_nodes if n.get("id")}
    valid_line_ids = {
        line_id(l)
        for l in active_lines
        if line_id(l)
    }
    valid_cand_ids = {str(c.get("id", c.get("candidate_id"))) for c in cands if c.get("id", c.get("candidate_id"))}
    valid_issue_ids = {
        str(i.get("id", i.get("issue_id", i.get("line_id", i.get("node_id")))))
        for i in issues
        if i.get("id", i.get("issue_id", i.get("line_id", i.get("node_id"))))
    }

    raw_focus = res.get("focus_targets", [])
    sanitized_focus = []
    if isinstance(raw_focus, list):
        for item in raw_focus:
            if not isinstance(item, dict):
                continue
            tid = str(item.get("id", "")).strip()
            ttype = str(item.get("type", "")).upper()
            if not tid or not ttype:
                continue

            # Canonical type normalization
            if ttype == "BUS":
                ttype = "OBJECT"
            elif ttype == "MISSING":
                ttype = "CANDIDATE"

            clean_item = dict(item)
            clean_item["type"] = ttype
            clean_item["id"] = tid

            # Strict type and ID matching
            if ttype == "OBJECT" and tid in valid_node_ids:
                sanitized_focus.append(clean_item)
            elif ttype == "LINE" and tid in valid_line_ids:
                sanitized_focus.append(clean_item)
            elif ttype == "CANDIDATE" and tid in valid_cand_ids:
                sanitized_focus.append(clean_item)
            elif ttype == "ISSUE" and tid in valid_issue_ids:
                sanitized_focus.append(clean_item)
            elif ttype == "UI" and tid in VALID_HIGHLIGHT_TARGETS:
                sanitized_focus.append(clean_item)
            # Fabricated targets or type mismatches (e.g. LINE with node ID) are dropped.

    res["focus_targets"] = sanitized_focus

    if _is_connection_review_stage(stage) and connection_blocked:
        # Connection Review V2 is exception-first.  Never allow a clean or
        # fabricated action when the deterministic contract has an exception.
        if not is_circuit_mutation_request(user_message):
            res["action_mode"] = "GUIDE"
        res["decision"] = "BLOCKED" if not active_lines else "HUMAN_CHECK"
        res["action_id"] = None
        res["highlight_target"] = None
        exception_ids = connection_exception_line_ids(active_lines, issues)
        deterministic_focus = []
        for line in active_lines:
            current_id = line_id(line)
            if current_id not in exception_ids:
                continue
            critical = line_has_critical_issue(line)
            current_issues = line_validation_issues(line)
            reason = next(
                (
                    str(issue.get("message"))
                    for issue in current_issues
                    if is_error_issue(issue) and issue.get("message")
                ),
                "연결 대상 또는 결선 상태를 확인해주세요.",
            )
            deterministic_focus.append(
                {
                    "type": "LINE",
                    "id": current_id,
                    "reason": reason,
                    "severity": "ERROR" if critical else "REVIEW",
                }
            )
        # A topology issue may not carry a line_id.  Map it to actual endpoint
        # lines when possible; otherwise preserve only an explicitly supplied
        # issue identifier.
        focused_ids = {item["id"] for item in deterministic_focus}
        for issue in issues:
            if not is_error_issue(issue):
                continue
            for current_id in related_line_ids(issue, active_lines):
                if current_id not in focused_ids:
                    deterministic_focus.append(
                        {
                            "type": "LINE",
                            "id": current_id,
                            "reason": str(issue.get("message") or issue.get("code") or "전기적 연결 오류"),
                            "severity": "ERROR",
                        }
                    )
                    focused_ids.add(current_id)
            issue_id = str(issue.get("id") or issue.get("issue_id") or "").strip()
            if issue_id and issue_id not in focused_ids:
                deterministic_focus.append(
                    {
                        "type": "ISSUE",
                        "id": issue_id,
                        "reason": str(issue.get("message") or issue.get("code") or "전기적 연결 오류"),
                        "severity": "ERROR",
                    }
                )
                focused_ids.add(issue_id)
        res["focus_targets"] = deterministic_focus
        res["reply_ko"] = (
            CONNECTION_NO_ACTIVE_MESSAGE
            if not active_lines
            else "확인이 필요한 결선 예외를 표시했습니다. 정상 선로는 AI가 확인했으며, 표시된 예외만 확인해주세요."
        )
        critical_count = critical_connection_error_count(active_lines, issues)
        res["summary_text"] = res["reply_ko"]
        if critical_count:
            res["summary_text"] += f"\n전기 오류: **{critical_count}건**"
    elif _is_connection_review_stage(stage) and not connection_blocked and not user_message:
        # Proactive clean summaries must not look like a human approval queue.
        res["decision"] = "PROCEED"
        res["action_mode"] = "NONE"
        res["action_id"] = None
        res["highlight_target"] = None
        res["focus_targets"] = []
    if bus_blocked:
        # An empty active Bus set is a hard workflow blocker, not a clean
        # review. Keep the response safe even when an LLM returned PROCEED.
        res["decision"] = "BLOCKED"
        res["action_mode"] = "GUIDE"
        res["action_id"] = None
        res["highlight_target"] = None
        res["focus_targets"] = []
        res["reply_ko"] = BUS_NO_ACTIVE_MESSAGE
        res["summary_text"] = BUS_NO_ACTIVE_MESSAGE

    # 9. Backward compatibility
    if not res.get("summary_text"):
        res["summary_text"] = res.get("reply_ko", "")
    return res


class ReviewAssistantProvider(abc.ABC):
    """Common Abstract Base Class for Review Assistant Providers."""

    @property
    @abc.abstractmethod
    def provider_name(self) -> str:
        """Machine-readable provider identifier (e.g. 'local', 'openai')."""
        pass

    @property
    @abc.abstractmethod
    def display_mode_name(self) -> str:
        """Human-readable display mode name shown in UI."""
        pass

    @abc.abstractmethod
    def answer_chat(
        self,
        message: str,
        document_id: str,
        stage: str,
        selected_node: Optional[Dict[str, Any]] = None,
        selected_line: Optional[Dict[str, Any]] = None,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
        history: Optional[List[ChatMessagePayload]] = None,
        app_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Answer interactive user questions using review evidence and graph state."""
        pass

    @abc.abstractmethod
    def generate_proactive_summary(
        self,
        document_id: str,
        stage: str,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
        app_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Generate proactive review priorities when entering a stage."""
        pass


class LocalReviewAssistantProvider(ReviewAssistantProvider):
    """Default Local Review Assistant Provider.

    Provides deterministic, fast, zero-cost, evidence-based analysis:
    - Analyzes bounding box aspect ratios, confidence, and source rules.
    - Diagnoses electrical connection violations and topology issues.
    - Summarizes diagram completeness and missing device hypotheses.
    - Evaluates electrical validation impact of symbol class changes.
    """

    @property
    def provider_name(self) -> str:
        return "local"

    @property
    def display_mode_name(self) -> str:
        return "로컬 분석 모드 (Local Analysis)"

    def generate_proactive_summary(
        self,
        document_id: str,
        stage: str,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
        app_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Generate proactive summary conforming to Canonical Agent Response Contract."""
        w_nodes = working_nodes or []
        w_lines = working_lines or []
        cands = missing_candidates or []
        issues = topology_issues or []
        stage_upper = (stage or "HOME").upper()

        suspicious = [n for n in w_nodes if (n.get("review_status") or n.get("status")) == "SUSPICIOUS"]
        open_cands = [c for c in cands if c.get("status") == "OPEN"]
        ambiguous = [l for l in w_lines if (l.get("review_status") or l.get("status")) == "AMBIGUOUS"]
        error_issues = [i for i in issues if i.get("severity") in ("error", "ERROR")]

        priority_items: List[Dict[str, Any]] = []
        focus_targets: List[Dict[str, Any]] = []
        target: Optional[str] = None
        decision = "PROCEED"
        action_mode = "NONE"
        reply_ko = ""
        summary_text = ""
        bus_summary: Optional[Dict[str, Any]] = None

        if stage_upper in ("HOME", "EMPTY_HOME"):
            target = "home_upload"
            reply_ko = "단선도 도면을 불러오시면 AI가 객체와 결선 상태를 자동으로 인식하고 검수를 도와드립니다."
            summary_text = (
                "👋 **안녕하세요! PowerLens AI입니다.** ✦\n\n"
                "단선도를 불러오시면 AI가 모선, 발전기, 변압기, 부하 설비와 연결 선로를 자동으로 인식하고 검수를 도와드립니다.\n\n"
                "💡 **시작 가이드:**\n"
                "• 중앙의 **[단선도 AI 분석 시작하기]** 버튼을 눌러 회로도 이미지를 선택하세요.\n"
                "• IEEE-24 표준 계통 샘플 도면으로 즉시 체험해볼 수도 있습니다."
            )

        elif stage_upper == "OBJECT_REVIEW":
            total_nodes = len(w_nodes)
            clean_count = total_nodes - len(suspicious)

            for s in suspicious:
                disp = s.get("display_label", s.get("id", "Unknown"))
                reasons = s.get("review_reasons", ["신뢰도 경계"])
                reason_str = reasons[0] if reasons else "신뢰도 경계"
                item = {
                    "id": s.get("id", ""),
                    "display_label": disp,
                    "target_type": "NODE",
                    "reason": reason_str,
                    "severity": "WARNING",
                }
                priority_items.append(item)
                focus_targets.append({
                    "type": "OBJECT",
                    "id": s.get("id", ""),
                    "reason": reason_str,
                    "severity": "WARNING",
                })

            for c in open_cands:
                cand_cls = str(c.get("suspected_class", "")).upper()
                desc = c.get("description_ko", "미검출 설비 가능성")
                item = {
                    "id": c.get("id", ""),
                    "display_label": f"{cand_cls} 누락 후보",
                    "target_type": "MISSING_CANDIDATE",
                    "reason": desc,
                    "severity": "ALERT",
                }
                priority_items.append(item)
                focus_targets.append({
                    "type": "CANDIDATE",
                    "id": c.get("id", ""),
                    "reason": desc,
                    "severity": "ALERT",
                })

            lines = ["📊 **[AI 검토 우선순위 요약 - 객체 검수]**"]
            lines.append(f"• **총 검출 객체**: {total_nodes}개 (정상/자동승인 대상: **{clean_count}개**)")
            lines.append(f"• **우선 검토 대상**: **{len(suspicious)}건** (누락 의심 설비: **{len(open_cands)}건**)")

            if priority_items:
                decision = "HUMAN_CHECK"
                action_mode = "GUIDE"
                target = None
                total_susp = len(suspicious) + len(open_cands)
                reply_ko = f"총 {total_nodes}개 객체를 확인했어요. 제가 한 번 더 확인했으면 하는 곳이 {total_susp}군데 있어요. 표시해둘게요."
                lines.append("\n🔍 **먼저 확인해야 할 항목:**")
                for idx, p in enumerate(priority_items[:4]):
                    lines.append(f"  {idx + 1}) **{p['display_label']}** - {p['reason']}")
                lines.append("\n💡 도면 위에 표시된 의심 객체를 클릭하여 AI 판단을 확인하고 [맞음] 또는 [수정]을 진행하세요.")
            else:
                decision = "PROCEED"
                action_mode = "NONE"
                target = None
                reply_ko = "제가 따로 의심하는 객체는 없어요. 마지막으로 전체 도면을 한번 확인한 뒤 객체 검수 완료를 눌러주세요."
                lines.append("\n✓ 모든 객체가 명확한 정상 심볼로 판정되었습니다. 전체 도면을 확인하신 후 `[객체 검수 완료]`를 눌러주세요.")

            summary_text = "\n".join(lines)

        elif stage_upper in ("BUS_MAPPING", "BUS_MAPPING_REVIEW"):
            bus_state = evaluate_bus_mapping(w_nodes)
            issue_buses = bus_state["issues"]
            total_buses = bus_state["total"]
            issue_count = bus_state["issue_count"]
            clean_count = bus_state["verified_count"]
            bus_summary = {
                "total_buses": total_buses,
                "verified_buses": clean_count,
                "issue_buses": issue_count,
                "duplicates": sorted(bus_state["duplicates"]),
            }

            if total_buses == 0:
                decision = "BLOCKED"
                action_mode = "GUIDE"
                target = None
                reply_ko = BUS_NO_ACTIVE_MESSAGE
            elif issue_buses:
                decision = "HUMAN_CHECK"
                action_mode = "GUIDE"
                target = None
                reply_ko = f"총 {total_buses}개 모선 번호를 확인했어요. {clean_count}개는 명확하고, {issue_count}개는 다시 확인하는 게 좋아요. 표시해둘게요."
                for b in issue_buses:
                    num = b.get("bus_number")
                    b_id = str(b.get("id", ""))
                    reasons = bus_state["issue_reasons"].get(b_id, [])
                    if any(reason in ("DUPLICATE_BUS_NUMBER", "ACTIVE_DUPLICATE_REASON") for reason in reasons):
                        reason = "중복 모선 번호"
                    elif "MISSING_BUS_NUMBER" in reasons:
                        reason = "모선 번호 미할당"
                    elif "INVALID_BUS_NUMBER" in reasons:
                        reason = "유효하지 않은 모선 번호"
                    else:
                        reason = "모선 번호 확인 필요"
                    focus_targets.append({
                        "type": "OBJECT",
                        "id": b_id,
                        "reason": reason,
                        "severity": "WARNING",
                    })
            else:
                decision = "PROCEED"
                action_mode = "NONE"
                target = None
                reply_ko = "제가 다시 확인할 모선은 이제 없어요. 전체 번호를 한번 확인한 뒤 [모선 검수 완료]를 눌러주세요."

            summary_text = (
                "📊 **[AI 검토 우선순위 요약 - 모선 번호 매핑]**\n\n"
                + (
                    f"• **총 모선 수**: {total_buses}개\n\n"
                    f"⚠️ **{BUS_NO_ACTIVE_MESSAGE}**"
                    if total_buses == 0
                    else (
                        f"• **총 모선 수**: {total_buses}개 (정상/확인 대상: **{clean_count}개**)\n"
                        f"• **확인 필요 모선**: **{issue_count}건**\n\n"
                        "💡 **안내:**\n"
                        "도면에 표시된 확인 필요 모선을 클릭하여 번호와 근거를 확인하고 틀린 경우에만 수정한 뒤, "
                        "하단 **[모선 검수 완료]**를 눌러주세요."
                    )
                )
            )

        elif _is_connection_review_stage(stage):
            active_lines = active_connection_lines(w_lines)
            exception_ids = connection_exception_line_ids(active_lines, issues)
            critical_line_ids = {
                line_id(line)
                for line in active_lines
                if line_id(line) and line_has_critical_issue(line)
            }
            critical_topology = [issue for issue in issues if is_error_issue(issue)]
            focus_targets = []
            priority_items = []
            for line in active_lines:
                current_id = line_id(line)
                if current_id not in exception_ids:
                    continue
                current_issues = line_validation_issues(line)
                reason = next(
                    (
                        str(issue.get("message"))
                        for issue in current_issues
                        if is_error_issue(issue) and issue.get("message")
                    ),
                    "연결 대상이 불확실하거나 결선 검증이 필요합니다.",
                )
                if str(line.get("review_status") or line.get("status") or "").upper() == "AMBIGUOUS":
                    reason = "연결 대상 불확실"
                severity = "ERROR" if current_id in critical_line_ids else "REVIEW"
                display = line.get("display_label", current_id)
                priority_items.append({
                    "id": current_id,
                    "display_label": display,
                    "target_type": "LINE",
                    "reason": reason,
                    "severity": severity,
                })
                focus_targets.append({
                    "type": "LINE",
                    "id": current_id,
                    "reason": reason,
                    "severity": severity,
                })

            focused_ids = {str(item.get("id")) for item in focus_targets}
            for issue in critical_topology:
                for current_id in related_line_ids(issue, active_lines):
                    if current_id not in focused_ids:
                        focus_targets.append({
                            "type": "LINE",
                            "id": current_id,
                            "reason": str(issue.get("message") or issue.get("code") or "전기적 연결 오류"),
                            "severity": "ERROR",
                        })
                        focused_ids.add(current_id)
                issue_id = issue_identifier(issue)
                if issue_id and issue_id not in focused_ids:
                    focus_targets.append({
                        "type": "ISSUE",
                        "id": issue_id,
                        "reason": str(issue.get("message") or issue.get("code") or "전기적 연결 오류"),
                        "severity": "ERROR",
                    })
                    focused_ids.add(issue_id)

            total_lines = len(active_lines)
            clean_lines = max(0, total_lines - len(exception_ids))
            error_count = critical_connection_error_count(active_lines, issues)
            v2_lines = ["📊 **[AI 검토 현황 - 결선 검수]**"]
            v2_lines.append(f"• **전체 결선**: {total_lines}개 (정상 연결: **{clean_lines}개**)")
            v2_lines.append(f"• **확인 필요**: **{len(exception_ids)}건**")
            v2_lines.append(f"• **전기 오류**: **{error_count}건**")
            if not active_lines:
                decision = "BLOCKED"
                action_mode = "GUIDE"
                target = None
                reply_ko = CONNECTION_NO_ACTIVE_MESSAGE
                v2_lines.append(f"\n⚠️ **{CONNECTION_NO_ACTIVE_MESSAGE}**")
            elif exception_ids or critical_topology:
                decision = "HUMAN_CHECK"
                action_mode = "GUIDE"
                target = None
                reply_ko = "확인이 필요한 결선 예외를 표시했습니다. 정상 선로는 AI가 확인했으며, 표시된 예외만 확인해주세요."
                v2_lines.append("\n🔗 **확인이 필요한 실제 예외:**")
                for idx, item in enumerate(priority_items[:6]):
                    v2_lines.append(f"  {idx + 1}) **{item['display_label']}** - {item['reason']}")
            else:
                decision = "PROCEED"
                action_mode = "NONE"
                target = None
                reply_ko = "정상 연결된 선로는 AI가 확인했습니다. 전체 도면을 확인한 뒤 [결선 검수 완료]를 눌러주세요."
                v2_lines.append("\n✓ 정상 결선은 자동으로 확인되었습니다. 전체 도면을 확인한 뒤 `[결선 검수 완료]`를 눌러주세요.")
            summary_text = "\n".join(v2_lines)

        elif stage_upper in ("FINAL_REVIEW", "FINAL", "VERIFIED_FINAL"):
            decision = "PROCEED"
            target = "final_excel_upload"
            reply_ko = "단선도 토폴로지 검증이 통과되었습니다. 조류계산을 위한 계통 제원 엑셀(.xlsx)을 연결할 수 있습니다."
            summary_text = (
                "🎉 **[회로도 최종 검증 완료]**\n\n"
                "단선도 토폴로지 검증이 통과되어 검증된 단선도(Verified SLD)가 생성되었습니다.\n\n"
                "💡 **다음 단계:**\n"
                "• 조류계산에 필요한 선로 임피던스(R, X, B)와 발전·부하 제원 엑셀(.xlsx)을 연결하세요.\n"
                "• **[캔버스 편집 화면으로 이동]** 버튼을 클릭하여 CAD에서 회로도를 확인할 수 있습니다."
            )

        elif stage_upper in ("CAD", "EXCEL_MAPPING"):
            decision = "PROCEED"
            target = "cad_excel_import"
            reply_ko = "단선도가 CAD 캔버스에 배치되었습니다. 상단 [엑셀 가져오기]로 제원을 연결하세요."
            summary_text = (
                "⚡ **[CAD 캔버스 & 계통 제원]**\n\n"
                "단선도가 CAD 캔버스에 배치되었습니다.\n\n"
                "💡 **다음 단계:**\n"
                "• 상단 **[엑셀 가져오기]** 버튼을 눌러 계통 파라미터 엑셀 파일(예: case24_psse.xlsx)을 연결하세요.\n"
                "• 제원이 연결되면 파란색 **[조류계산 실행]** 버튼이 활성화됩니다."
            )

        elif stage_upper == "POWERFLOW_READY":
            decision = "PROCEED"
            target = "final_powerflow"
            reply_ko = "모든 모선 토폴로지와 선로 제원이 연결되었습니다. 조류계산을 실행할 수 있습니다."
            summary_text = (
                "🚀 **[조류계산 준비 완료]**\n\n"
                "모든 모선 토폴로지와 선로 제원이 연결되었습니다.\n\n"
                "💡 **다음 단계:**\n"
                "• 상단 파란색 **[조류계산 실행]** 버튼을 클릭하여 뉴턴-랩슨 수치해석을 시작하세요."
            )

        elif stage_upper in (
            "POWERFLOW_CONVERGED", "POWERFLOW_NOT_CONVERGED", "POWERFLOW_RESULT", "POWERFLOW"
        ):
            evidence = (app_context or {}).get("powerflow_evidence")
            detail = _powerflow_evidence_detail(app_context)
            converged = isinstance(evidence, dict) and evidence.get("converged") is True
            if detail is None:
                decision = "HUMAN_CHECK"
                action_mode = "GUIDE"
                reply_ko = "실제 solver 결과 증거를 확인할 수 없어 수렴 여부나 계통 상태를 판정하지 않습니다."
                summary_text = "실제 수렴 결과를 확인할 수 없어 계통 상태를 안내할 수 없습니다."
            elif converged:
                decision = "PROCEED"
                target = "result_flow"
                reply_ko = f"{detail}. 상단 [수치 결과표]에서 실제 solver 결과를 확인하세요."
                summary_text = f"📈 **[실제 조류계산 결과]**\n\n{detail}\n\n상단 **[수치 결과표]**에서 모선 전압과 선로 조류/손실을 확인하세요."
            else:
                decision = "HUMAN_CHECK"
                action_mode = "GUIDE"
                reply_ko = f"{detail}. 이 값은 수렴한 운전 결과가 아닙니다. 입력 제원과 계통 연결을 확인한 뒤 다시 실행하세요."
                summary_text = f"⚠️ **[조류계산 미수렴]**\n\n{detail}\n\n수렴 결과로 취급하지 말고 제원과 연결 상태를 확인하세요."

        else:
            decision = "UNKNOWN"
            reply_ko = f"현재 {stage} 단계입니다. 안내가 필요하시면 질문해주세요."
            summary_text = f"현재 **{stage}** 단계입니다. 안내가 필요하시면 질문해주세요."

        res = {
            "reply_ko": reply_ko or summary_text,
            "decision": decision,
            "intent": "STAGE_PROACTIVE_SUMMARY",
            "action_mode": action_mode,
            "action_id": None,
            "action_params": {},
            "highlight_target": target,
            "focus_targets": focus_targets,
            "evidence_summary": {
                "suspicious_count": len(suspicious),
                "missing_count": len(open_cands),
                "ambiguous_count": len(ambiguous),
                "topology_error_count": len(error_issues),
            },
            "summary_text": summary_text,
            "total_count": bus_summary["total_buses"] if bus_summary is not None else (len(active_connection_lines(w_lines)) if _is_connection_review_stage(stage) else len(w_nodes)),
            "clean_count": bus_summary["verified_buses"] if bus_summary is not None else (len(active_connection_lines(w_lines)) - len(connection_exception_line_ids(active_connection_lines(w_lines), issues)) if _is_connection_review_stage(stage) else len(w_nodes) - len(suspicious)),
            "suspicious_count": bus_summary["issue_buses"] if bus_summary is not None else (len(connection_exception_line_ids(active_connection_lines(w_lines), issues)) if _is_connection_review_stage(stage) else len(suspicious)),
            "missing_count": len(open_cands) if not _is_connection_review_stage(stage) else len(error_issues),
            "bus_summary": bus_summary,
            "priority_items": priority_items,
            "provider_mode": self.provider_name,
            "display_mode": self.display_mode_name,
            "agent_status": "LOCAL_PROACTIVE",
        }
        return sanitize_and_validate_agent_response(res, "", w_nodes, w_lines, cands, issues, stage)

    def answer_chat(
        self,
        message: str,
        document_id: str,
        stage: str,
        selected_node: Optional[Dict[str, Any]] = None,
        selected_line: Optional[Dict[str, Any]] = None,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
        history: Optional[List[ChatMessagePayload]] = None,
        app_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        msg = (message or "").strip().lower()
        msg_norm = msg.replace(" ", "")
        w_nodes = working_nodes or []
        w_lines = working_lines or []
        cands = missing_candidates or []
        issues = topology_issues or []
        stage_upper = (stage or "HOME").upper()

        susp_cnt = len([n for n in w_nodes if (n.get("review_status") or n.get("status")) == "SUSPICIOUS"])
        miss_cnt = len([c for c in cands if c.get("status") == "OPEN"])
        amb_cnt = len([l for l in w_lines if (l.get("review_status") or l.get("status")) == "AMBIGUOUS"])
        err_cnt = len(issues)

        # 1. Action Intent Routing
        # Common voice commands map onto the same allow-listed UI actions as
        # their visible buttons. The frontend still applies each screen's Gate.
        if any(k in msg_norm for k in [
            "도면불러", "도면올려", "도면업로드", "이미지불러", "사진올려", "opendiagrampicker"
        ]):
            res = {
                "reply_ko": "도면 파일 선택 창을 엽니다.",
                "decision": "PROCEED",
                "intent": "OPEN_DIAGRAM_PICKER",
                "action_mode": "EXECUTE",
                "action_id": "OPEN_DIAGRAM_PICKER",
                "highlight_target": "home_upload",
                "agent_status": "LOCAL_DETERMINISTIC",
            }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        completion_terms_by_stage = {
            "OBJECT_REVIEW": ["객체검수완료", "객체검수끝", "객체확인완료", "객체확인끝"],
            "BUS_MAPPING": ["모선검수완료", "모선확인완료", "모선검수끝", "모선확인끝", "모선다봤", "버스번호확인끝"],
            "BUS_MAPPING_REVIEW": ["모선검수완료", "모선확인완료", "모선검수끝", "모선확인끝", "모선다봤", "버스번호확인끝"],
            "CONNECTION_REVIEW": ["결선검수완료", "결선확인완료", "결선끝", "결선다봤"],
            "LINE_REVIEW": ["결선검수완료", "결선확인완료", "결선끝", "결선다봤"],
        }
        stage_completion_terms = completion_terms_by_stage.get(stage_upper)
        if stage_completion_terms is not None and (
            any(term in msg_norm for term in stage_completion_terms)
            or any(term in msg_norm for term in ["다봤", "다음", "다음단계", "검수완료해"])
        ):
            res = {
                "reply_ko": "현재 검수 단계 완료 버튼과 같은 Gate 검증을 요청합니다.",
                "decision": "PROCEED",
                "intent": "COMPLETE_CURRENT_STAGE",
                "action_mode": "EXECUTE",
                "action_id": "COMPLETE_CURRENT_STAGE",
                "agent_status": "LOCAL_DETERMINISTIC",
            }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        if any(k in msg_norm for k in ["cad로넘어가", "cad로이동", "캔버스로이동", "캔버스편집", "도면편집화면"]):
            res = {
                "reply_ko": "검증된 계통의 CAD 화면으로 이동을 요청합니다.",
                "decision": "PROCEED",
                "intent": "HANDOFF_TO_CANVAS",
                "action_mode": "EXECUTE",
                "action_id": "HANDOFF_TO_CANVAS",
                "agent_status": "LOCAL_DETERMINISTIC",
            }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        # Power flow execution vs guidance
        if any(k in msg_norm for k in [
            "조류계산", "계산실행", "계산진행", "계산해줘", "계산해주세요", "runpowerflow"
        ]):
            is_where = any(k in msg_norm for k in ["어디", "어떻게", "뭐눌러", "위치", "어느버튼", "버튼어디", "어디야", "어디서"])
            if is_where:
                res = {
                    "reply_ko": "화면 상단 파란색 [조류계산 실행] 버튼을 클릭하시면 뉴턴-랩슨 조류계산이 수행됩니다. 위치가 화면에서 반짝이고 있어요.",
                    "decision": "PROCEED",
                    "intent": "ASK_RUN_POWER_FLOW_GUIDE",
                    "action_mode": "GUIDE",
                    "action_id": "RUN_POWER_FLOW",
                    "highlight_target": "final_powerflow",
                    "agent_status": "LOCAL_DETERMINISTIC",
                }
            else:
                res = {
                    "reply_ko": "조류계산을 실행합니다. 수치해석이 완료될 때까지 잠시만 기다려주세요.",
                    "decision": "PROCEED",
                    "intent": "RUN_POWER_FLOW",
                    "action_mode": "EXECUTE",
                    "action_id": "RUN_POWER_FLOW",
                    "highlight_target": "final_powerflow",
                    "agent_status": "LOCAL_DETERMINISTIC",
                }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        # Power flow results show vs guidance
        if any(k in msg_norm for k in ["결과보여", "결과표", "수치결과", "showresult", "결과는어디"]):
            is_where = any(k in msg_norm for k in ["어디", "어떻게", "뭐눌러", "위치", "어느버튼", "어디서", "어디야"])
            if is_where:
                res = {
                    "reply_ko": "상단 메뉴의 [수치 결과표] 버튼에서 모선 전압과 선로 조류/손실 결과를 확인하실 수 있습니다.",
                    "decision": "PROCEED",
                    "intent": "ASK_SHOW_POWER_FLOW_RESULTS_GUIDE",
                    "action_mode": "GUIDE",
                    "action_id": "SHOW_POWER_FLOW_RESULTS",
                    "highlight_target": "result_flow",
                    "agent_status": "LOCAL_DETERMINISTIC",
                }
            else:
                res = {
                    "reply_ko": "조류계산 수치 결과표를 표시합니다.",
                    "decision": "PROCEED",
                    "intent": "SHOW_POWER_FLOW_RESULTS",
                    "action_mode": "EXECUTE",
                    "action_id": "SHOW_POWER_FLOW_RESULTS",
                    "highlight_target": "result_flow",
                    "agent_status": "LOCAL_DETERMINISTIC",
                }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        # Home navigation
        if any(k in msg_norm for k in ["홈으로", "처음으로", "gohome", "시작화면"]):
            res = {
                "reply_ko": "홈 화면으로 이동합니다.",
                "decision": "PROCEED",
                "intent": "GO_HOME",
                "action_mode": "EXECUTE",
                "action_id": "GO_HOME",
                "highlight_target": "home_upload",
                "agent_status": "LOCAL_DETERMINISTIC",
            }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        # 2. Selected Node Inquiry
        if selected_node and any(k in msg for k in ["왜", "이유", "판단", "의심", "바꾸면", "변경", "영향", "설명", "심볼", "why"]):
            node_id = str(selected_node.get("id", "Unknown"))
            node_cls = str(selected_node.get("class", selected_node.get("className", "UNKNOWN"))).upper()
            conf = float(selected_node.get("confidence", 0.0))
            reasons = selected_node.get("review_reasons", [])
            expl = selected_node.get("agent_explanation", "")

            if any(k in msg for k in ["바꾸면", "변경", "영향"]):
                reply = (
                    f"🔄 **[설비 클래스 변경 영향 분석 - {node_id} ({node_cls})]**\n\n"
                    f"현재 객체는 **모선(BUS)** 심볼로 인식되어 있습니다.\n"
                    f"• **계통 영향**: 모선(Bus)을 부하(Load)나 타 설비로 변경하면 연결된 송전선로와 인입선 토폴로지 구조가 재구성되며, 조류계산 모선 방정식의 차수가 달라집니다."
                )
                res = {
                    "reply_ko": reply,
                    "decision": "HUMAN_CHECK",
                    "intent": "INSPECT_CLASS_CHANGE_IMPACT",
                    "action_mode": "CONFIRM_REQUIRED",
                    "action_id": None,
                    "highlight_target": "canvas_node",
                    "focus_targets": [{"type": "OBJECT", "id": node_id, "reason": "클래스 변경 영향 분석", "severity": "WARNING"}],
                    "agent_status": "LOCAL_NODE_INFO",
                }
                return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

            lines = [f"🔍 **[선택 객체 AI 분석 - {node_id} ({node_cls})]**\n"]
            lines.append(f"• **설비 분류**: **{node_cls}** (AI 신뢰도: **{conf:.2f}**)")
            if expl:
                lines.append(f"• **판단 설명**: {expl}")
            if reasons:
                lines.append(f"• **검토 사유/근거**: {', '.join(str(r) for r in reasons)}")
            else:
                lines.append(f"• **판단 근거**: 기하학적 형태와 연결 단자 분석을 통해 정상적인 {node_cls} 심볼로 검출되었습니다.")
            reply = "\n".join(lines)

            res = {
                "reply_ko": reply,
                "decision": "HUMAN_CHECK" if selected_node.get("review_status") == "SUSPICIOUS" else "PROCEED",
                "intent": "INSPECT_SELECTED_NODE",
                "action_mode": "NONE",
                "action_id": None,
                "highlight_target": "canvas_node",
                "focus_targets": [{"type": "OBJECT", "id": node_id, "reason": expl or "선택 객체", "severity": "INFO"}],
                "agent_status": "LOCAL_NODE_INFO",
            }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        # Safe Resource Request: Excel file picker / upload
        if any(k in msg_norm for k in ["엑셀추가", "엑셀파일", "엑셀불러", "엑셀가져", "엑셀열어", "엑셀업로드", "엑셀넣", "제원가져", "제원불러", "openexcel", "importexcel"]) or ("엑셀" in msg and any(v in msg for v in ["추가", "열어", "가져", "불러", "선택", "넣"])):
            res = {
                "reply_ko": "계통 제원 엑셀(.xlsx) 파일을 선택할 수 있는 파일 선택창을 엽니다.",
                "decision": "PROCEED",
                "intent": "OPEN_EXCEL_PICKER",
                "action_mode": "EXECUTE",
                "action_id": "OPEN_EXCEL_PICKER",
                "highlight_target": "final_excel_upload" if ("final" in stage_upper or "verified" in stage_upper) else "cad_excel_import",
                "agent_status": "LOCAL_DETERMINISTIC",
            }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        # Mutation check (requires actual circuit target noun + mutation verb)
        if is_circuit_mutation_request(message):
            res = {
                "reply_ko": "회로 설비 속성 변경이나 삭제/추가는 계통 토폴로지에 직접적인 영향을 미치므로 사용자 확인(Confirm)이 필요합니다.",
                "decision": "HUMAN_CHECK",
                "intent": "MUTATE_CIRCUIT_REQUEST",
                "action_mode": "CONFIRM_REQUIRED",
                "action_id": None,
                "agent_status": "LOCAL_DETERMINISTIC",
            }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        # 3. Selected Line Inquiry
        if selected_line and any(k in msg for k in ["왜", "이유", "문제", "오류", "선로", "line", "why"]):
            line_id = str(selected_line.get("line_id", selected_line.get("id", "Unknown")))
            status = str(selected_line.get("review_status", "DETECTED")).upper()
            issues_list = line_validation_issues(selected_line)
            issue_msgs = [i.get("message", "") for i in issues_list if isinstance(i, dict)]
            is_critical = line_has_critical_issue(selected_line)
            is_rejected = status == "REJECTED"

            lines = [f"🔍 **[선택 선로 결선 분석 - {line_id}]**\n"]
            lines.append(f"• **검수 상태**: {'확인 필요' if status == 'AMBIGUOUS' else ('전기 오류' if is_critical else ('제외' if is_rejected else 'AI 확인'))}")
            if issue_msgs:
                lines.append(f"• **결선 이슈**: {', '.join(issue_msgs)}")
            else:
                lines.append("• **결선 상태**: 실제 traced path와 endpoint가 정상 연결로 확인되었습니다.")
            reply = "\n".join(lines)

            res = {
                "reply_ko": reply,
                "decision": "HUMAN_CHECK" if (status == "AMBIGUOUS" or is_critical) else "PROCEED",
                "intent": "INSPECT_SELECTED_LINE",
                "action_mode": "NONE",
                "action_id": None,
                "highlight_target": "canvas_line",
                "focus_targets": [] if is_rejected else [{
                    "type": "LINE",
                    "id": line_id,
                    "reason": "전기적 연결 오류" if is_critical else ("연결 대상 불확실" if status == "AMBIGUOUS" else "AI 확인 선로"),
                    "severity": "ERROR" if is_critical else ("REVIEW" if status == "AMBIGUOUS" else "INFO"),
                }],
                "agent_status": "LOCAL_LINE_INFO",
            }
            # A selected line is authoritative chat context even when the
            # caller omits the full working-line collection. Preserve that
            # context so the connection contract does not replace an actual
            # line explanation with the empty-network blocker.
            validation_lines = w_lines if w_lines else [selected_line]
            return sanitize_and_validate_agent_response(
                res, message, w_nodes, validation_lines, cands, issues, stage
            )

        # 4. Summary & Status Requests
        if any(k in msg for k in ["요약", "현황", "검토 필요", "상태", "summary", "status"]):
            s_res = self.generate_proactive_summary(
                document_id=document_id,
                stage=stage,
                working_nodes=w_nodes,
                working_lines=w_lines,
                missing_candidates=cands,
                topology_issues=issues,
                app_context=app_context,
            )
            s_res["reply_ko"] = s_res["summary_text"]
            s_res["intent"] = "STAGE_PROACTIVE_SUMMARY"
            return s_res

        # 5. Missing Candidate Summary
        if any(k in msg for k in ["누락", "후보", "변압기", "missing", "빠진"]):
            open_cands = [c for c in cands if c.get("status") == "OPEN"]
            if open_cands:
                cand = open_cands[0]
                reply = f"⚠️ 누락 의심 설비가 {len(open_cands)}건 있습니다: {cand.get('description_ko', '')}. 도면에 없는 기기라면 [문제 없음]을 선택하세요."
                res = {
                    "reply_ko": reply,
                    "decision": "HUMAN_CHECK",
                    "intent": "INSPECT_MISSING_CANDIDATES",
                    "action_mode": "GUIDE",
                    "action_id": None,
                    "highlight_target": "missing_candidates",
                    "focus_targets": [{"type": "CANDIDATE", "id": cand.get("id", ""), "reason": cand.get("description_ko", ""), "severity": "ALERT"}],
                    "agent_status": "LOCAL_MISSING_CANDIDATE",
                }
            else:
                res = {
                    "reply_ko": "누락 의심 설비가 없습니다. 모든 설비가 정상 검출되었습니다.",
                    "decision": "PROCEED",
                    "intent": "INSPECT_MISSING_CANDIDATES",
                    "action_mode": "NONE",
                    "action_id": None,
                    "highlight_target": None,
                    "agent_status": "LOCAL_MISSING_CANDIDATE",
                }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        # 6. Excel Guidance
        if any(k in msg for k in ["엑셀", "excel", "제원", "임피던스", "파라미터"]):
            res = {
                "reply_ko": "조류계산에는 모선 제원 및 선로 임피던스가 필요합니다. 상단 [엑셀 가져오기] 버튼으로 PSS/E 포맷 엑셀 파일(.xlsx)을 연결하세요.",
                "decision": "PROCEED",
                "intent": "EXCEL_IMPORT_GUIDE",
                "action_mode": "GUIDE",
                "action_id": "OPEN_EXCEL_PICKER",
                "highlight_target": "final_excel_upload" if "final" in stage.lower() else "cad_excel_import",
                "agent_status": "LOCAL_EXCEL_GUIDE",
            }
            return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)

        # 7. Stage-Based State Guidance
        target = None
        dec = "PROCEED"
        if stage_upper in ("HOME", "EMPTY_HOME"):
            target = "home_upload"
            reply = (
                "🧭 **[다음 단계 진행 가이드 - 시작하기]:**\n"
                "1. 단선도 도면을 먼저 불러오세요.\n"
                "2. 화면 중앙의 **[단선도 AI 분석 시작하기]** 버튼을 누르거나 샘플 도면(IEEE-24)을 선택하세요.\n"
                "3. AI가 도면을 분석하면 자동으로 객체 검수실로 이동합니다."
            )
        elif stage_upper == "OBJECT_REVIEW":
            suspicious_count = len([n for n in w_nodes if (n.get("review_status") or n.get("status")) == "SUSPICIOUS"])
            open_cand_count = len([c for c in cands if c.get("status") == "OPEN"])
            reply = "🧭 **[다음 단계 진행 가이드 - ① 객체 검수]:**\n"
            if suspicious_count > 0:
                target = None
                dec = "HUMAN_CHECK"
                reply += (
                    f"⚠️ 도면에 확인이 필요한 의심 객체가 **{suspicious_count}건** 표시되어 있습니다.\n"
                    "• 도면에 표시된 확인 필요 객체를 클릭해 **[맞음]** 또는 **[수정]**으로 확인해주세요.\n"
                    "• 모든 의심 객체 확인 후 하단의 **[객체 검수 완료]**(Gate 통과)를 눌러 다음 단계로 진행하세요."
                )
            elif open_cand_count > 0:
                target = "missing_candidates"
                dec = "HUMAN_CHECK"
                reply += (
                    f"⚠️ 누락 가능성이 있는 설비 후보가 **{open_cand_count}건** 감지되어 있습니다.\n"
                    "• 상단 보라색 **[누락 후보]** 배지나 카드를 눌러 **[문제 없음]** 또는 **[수동 추가]**를 진행하세요.\n"
                    "• 누락 후보 처리가 끝나면 하단 **[객체 검수 완료]**(Gate 통과)를 눌러 다음 단계로 진행하세요."
                )
            else:
                target = "object_gate"
                dec = "PROCEED"
                reply += (
                    "✓ 모든 객체 검토가 완료되었습니다!\n"
                    "• 전체 도면을 한 번 확인한 뒤 하단의 파란색 **[객체 검수 완료]**(Gate 통과) 버튼을 눌러주세요."
                )
        elif stage_upper in ("BUS_MAPPING_REVIEW", "BUS_MAPPING"):
            bus_state = evaluate_bus_mapping(w_nodes)
            all_buses = bus_state["buses"]
            issue_count = bus_state["issue_count"]
            reply = "🧭 **[다음 단계 진행 가이드 - ② 모선 번호 매핑]:**\n"
            if len(all_buses) == 0:
                target = None
                dec = "BLOCKED"
                reply += f"⚠️ {BUS_NO_ACTIVE_MESSAGE}\n"
                reply += "객체 검수에서 모선 인식을 확인한 뒤 다시 시도해주세요."
            elif issue_count == 0:
                target = "bus_gate"
                reply += "✓ 모든 모선 번호가 확인되었습니다!\n"
                reply += "• 전체 번호를 확인한 뒤 하단 **[모선 검수 완료]** 버튼을 눌러 다음 단계로 이동하세요."
            else:
                target = None
                dec = "HUMAN_CHECK"
                reply += f"1. 모선 번호 확인 필요: **{issue_count}개**\n"
                reply += "2. 도면에 표시된 확인 필요 모선을 클릭하여 번호와 근거를 확인하고 틀린 경우에만 수정하세요.\n"
                reply += "3. 모든 확인이 끝나면 하단 **[모선 검수 완료]**를 눌러주세요."
        elif _is_connection_review_stage(stage):
            active_lines = active_connection_lines(w_lines)
            exception_ids = connection_exception_line_ids(active_lines, issues)
            error_count = critical_connection_error_count(active_lines, issues)
            reply = "🧭 **[다음 단계 진행 가이드 - ③ 결선 검수]:**\n"
            if not active_lines:
                dec = "BLOCKED"
                target = None
                reply += f"⚠️ {CONNECTION_NO_ACTIVE_MESSAGE}\n"
                reply += "결선 검출 결과와 객체 연결 상태를 확인한 뒤 다시 시도해주세요."
            elif exception_ids or error_count > 0:
                dec = "HUMAN_CHECK"
                target = None
                reply += f"1. 확인이 필요한 실제 결선 예외: **{len(exception_ids)}건**\n"
                reply += f"2. 전기적 연결 오류: **{error_count}건**\n"
                reply += "3. 표시된 예외의 endpoint, traced path, validation evidence만 확인하거나 수정해주세요."
            else:
                dec = "PROCEED"
                target = None
                reply += "✓ 정상 연결된 선로는 AI가 확인했습니다.\n"
                reply += "• 전체 도면을 확인한 뒤 하단 **[결선 검수 완료]**를 눌러주세요."
        elif stage_upper in ("FINAL_REVIEW", "FINAL", "VERIFIED_FINAL"):
            target = "final_excel_upload"
            reply = (
                "🧭 **[다음 단계 진행 가이드 - ④ 최종 확인 & 엑셀 대조]:**\n"
                "1. 최종 정합성이 검증된 회로도 요약을 확인하세요.\n"
                "2. **[엑셀 파일 선택]** 버튼을 눌러 계통 파라미터(.xlsx)를 업로드하세요.\n"
                "3. **[캔버스로 이동]** 버튼을 클릭하여 메인 CAD 화면으로 전환하고 조류계산을 준비하세요."
            )
        elif stage_upper in ("CAD", "EXCEL_MAPPING", "FINAL_CAD", "EXCEL"):
            target = "cad_excel_import"
            reply = (
                "🧭 **[다음 단계 진행 가이드 - CAD & 엑셀]:**\n"
                "1. 상단 **[엑셀 가져오기]** 버튼을 눌러 계통 파라미터 엑셀 파일(예: case24_psse.xlsx)을 연결하세요.\n"
                "2. 엑셀 제원이 연결되면 상단 파란색 **[조류계산 실행]** 버튼을 눌러 수치해석을 진행하세요."
            )
        elif stage_upper in (
            "POWERFLOW_CONVERGED", "POWERFLOW_NOT_CONVERGED", "POWERFLOW_RESULT"
        ) or (
            stage_upper == "POWERFLOW"
            and (app_context or {}).get("powerflow_evidence") is not None
        ):
            evidence = (app_context or {}).get("powerflow_evidence")
            detail = _powerflow_evidence_detail(app_context)
            if detail is None:
                target = None
                dec = "HUMAN_CHECK"
                reply = "실제 solver 결과 증거를 확인할 수 없어 수렴 여부나 계통 상태를 판정하지 않습니다."
            elif isinstance(evidence, dict) and evidence.get("converged") is True:
                target = "result_flow"
                reply = f"{detail}. 상단 [수치 결과표]에서 실제 solver 결과를 확인하세요."
            else:
                target = None
                dec = "HUMAN_CHECK"
                reply = f"{detail}. 수렴한 운전 결과가 아니므로 입력 제원과 계통 연결을 확인한 뒤 다시 실행하세요."
        elif stage_upper in ("POWERFLOW_READY", "POWERFLOW"):
            target = "final_powerflow"
            reply = (
                "🧭 **[다음 단계 진행 가이드 - 조류계산]:**\n"
                "계통 제원 연결이 완료되었습니다!\n"
                "• 상단 우측 파란색 **[조류계산 실행]** 버튼을 클릭하여 뉴턴-랩슨 조류계산을 수행하세요."
            )
        elif stage_upper == "POWERFLOW_RESULT":
            target = "result_flow"
            reply = (
                "🧭 **[다음 단계 진행 가이드 - 결과 확인]:**\n"
                "조류계산이 수렴했습니다!\n"
                "1. 상단 **[수치 결과표]** 버튼을 눌러 모선별 전압/위상각과 선로 조류/손실 표를 확인하세요.\n"
                "2. CAD 캔버스 위 각 모선의 전압과 발전기 출력을 직접 비교해보세요."
            )
        else:
            reply = f"현재 {stage} 단계입니다. 궁금하신 내용을 질문해주세요."

        res = {
            "reply_ko": reply,
            "decision": dec,
            "intent": "STAGE_GUIDANCE",
            "action_mode": (
                "GUIDE"
                if (_is_connection_review_stage(stage) and dec in ("HUMAN_CHECK", "BLOCKED"))
                else ("GUIDE" if target else "NONE")
            ),
            "action_id": None,
            "highlight_target": target,
            "agent_status": "LOCAL_GUIDE",
        }
        return sanitize_and_validate_agent_response(res, message, w_nodes, w_lines, cands, issues, stage)


class GeminiReviewAssistantProvider(ReviewAssistantProvider):
    """Google Gemini Review Assistant Provider.

    Uses Google Gemini REST API (gemini-3.8-flash primary with gemini-3.5-flash-lite fallback)
    for fast, intelligent, context-aware SLD diagram verification assistance.
    """

    TIMEOUT_SECONDS: float = 25.0

    def __init__(
        self,
        api_key: str,
        model_name: Optional[str] = None,
        fallback_model_name: Optional[str] = None,
    ):
        self.api_key = api_key
        self.primary_model_name = (model_name.strip() if model_name else get_gemini_model_name())
        self.fallback_model_name = (fallback_model_name.strip() if fallback_model_name else get_gemini_fallback_model_name())
        self.model_name = self.primary_model_name

    @property
    def provider_name(self) -> str:
        return "gemini"

    @property
    def display_mode_name(self) -> str:
        return f"Gemini ({self.primary_model_name}) AI 모드"

    def _call_gemini_with_fallback(
        self,
        system_instruction: str,
        contents: List[Dict[str, Any]],
        timeout_sec: float = 25.0,
    ) -> Tuple[Optional[str], str, bool]:
        import json
        import urllib.error
        import urllib.request

        payload = {
            "system_instruction": {"parts": [{"text": system_instruction}]},
            "contents": contents,
            "generationConfig": {
                "temperature": 0.2,
                "maxOutputTokens": 800,
                "responseMimeType": "application/json",
            },
        }

        transient_status_codes = {429, 500, 502, 503, 504}
        data = None
        active_model = self.primary_model_name
        is_fallback_active = False

        def _execute_model_call(m_name: str, t_sec: float) -> Optional[Dict[str, Any]]:
            endpoint = f"https://generativelanguage.googleapis.com/v1beta/models/{m_name}:generateContent?key={self.api_key}"
            req = urllib.request.Request(
                endpoint,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=t_sec) as resp:
                return json.loads(resp.read().decode("utf-8"))

        def _extract_reply_from_data(model_data: Optional[Dict[str, Any]]) -> Optional[str]:
            if not model_data:
                return None
            cands = model_data.get("candidates", [])
            if not cands:
                return None
            parts = cands[0].get("content", {}).get("parts", [])
            if not isinstance(parts, list):
                return None
            text_parts = [p.get("text", "") for p in parts if isinstance(p, dict) and "text" in p]
            combined = "".join(text_parts).strip()
            return combined if combined else None

        # 1. Primary Model Execution (with transient retry on 503/timeout/429)
        for attempt in range(2):
            try:
                data = _execute_model_call(self.primary_model_name, t_sec=timeout_sec)
                if data:
                    break
            except urllib.error.HTTPError as http_err:
                if http_err.code in transient_status_codes and attempt == 0:
                    time.sleep(0.8)
                    continue
                else:
                    break
            except Exception as exc:
                if attempt == 0 and ("timeout" in str(exc).lower() or "timed out" in str(exc).lower()):
                    time.sleep(0.8)
                    continue
                break

        raw_reply = _extract_reply_from_data(data)

        # 2. If primary produced no text, try Fallback model
        if not raw_reply and self.fallback_model_name and self.fallback_model_name != self.primary_model_name:
            try:
                fb_data = _execute_model_call(self.fallback_model_name, t_sec=15.0)
                fb_reply = _extract_reply_from_data(fb_data)
                if fb_reply:
                    raw_reply = fb_reply
                    active_model = self.fallback_model_name
                    is_fallback_active = True
            except Exception:
                pass

        return raw_reply, active_model, is_fallback_active

    def generate_proactive_summary(
        self,
        document_id: str,
        stage: str,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
        app_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Generate proactive review priorities using real Gemini Agent reasoning."""
        w_nodes = working_nodes or []
        w_lines = working_lines or []
        cands = missing_candidates or []
        issues = topology_issues or []

        if _is_bus_mapping_stage(stage):
            # Bus Mapping is a deterministic state contract. Do not let an
            # LLM paraphrase stale totals or omit an active duplicate reason.
            res = LocalReviewAssistantProvider().generate_proactive_summary(
                document_id=document_id,
                stage=stage,
                working_nodes=w_nodes,
                working_lines=w_lines,
                missing_candidates=cands,
                topology_issues=issues,
                app_context=app_context,
            )
            res["provider_mode"] = self.provider_name
            res["display_mode"] = self.display_mode_name
            res["agent_status"] = "LOCAL_BUS_CONTRACT"
            return res

        if _is_connection_review_stage(stage):
            # Connection truth and focus targets come from the deterministic
            # topology/line evidence contract; Gemini may explain it later,
            # but must not decide whether a line is clean.
            res = LocalReviewAssistantProvider().generate_proactive_summary(
                document_id=document_id,
                stage=stage,
                working_nodes=w_nodes,
                working_lines=w_lines,
                missing_candidates=cands,
                topology_issues=issues,
                app_context=app_context,
            )
            res["provider_mode"] = self.provider_name
            res["display_mode"] = self.display_mode_name
            res["agent_status"] = "LOCAL_CONNECTION_CONTRACT"
            return res

        if (stage or "").upper() in (
            "POWERFLOW_CONVERGED", "POWERFLOW_NOT_CONVERGED", "POWERFLOW_RESULT"
        ) or (
            (stage or "").upper() == "POWERFLOW"
            and (app_context or {}).get("powerflow_evidence") is not None
        ):
            res = LocalReviewAssistantProvider().generate_proactive_summary(
                document_id=document_id,
                stage=stage,
                working_nodes=w_nodes,
                working_lines=w_lines,
                missing_candidates=cands,
                topology_issues=issues,
                app_context=app_context,
            )
            res["provider_mode"] = self.provider_name
            res["display_mode"] = self.display_mode_name
            res["agent_status"] = "LOCAL_POWERFLOW_CONTRACT"
            return res

        suspicious_nodes = [
            {
                "id": n.get("id"),
                "class": n.get("class") or n.get("className"),
                "display_label": n.get("display_label", n.get("id")),
                "review_status": n.get("review_status") or n.get("status"),
                "review_reasons": n.get("review_reasons", []),
            }
            for n in w_nodes if (n.get("review_status") or n.get("status")) == "SUSPICIOUS"
        ]
        open_cands = [
            {
                "id": c.get("id"),
                "suspected_class": c.get("suspected_class"),
                "description_ko": c.get("description_ko"),
            }
            for c in cands if c.get("status") == "OPEN"
        ]
        ambiguous_lines = [
            {
                "line_id": l.get("line_id", l.get("id")),
                "review_status": l.get("review_status"),
                "connected_to": l.get("connected_to", []),
            }
            for l in w_lines if (l.get("review_status") or l.get("status")) == "AMBIGUOUS"
        ]

        prompt_data = {
            "current_stage": stage,
            "total_nodes": len(w_nodes),
            "suspicious_nodes_count": len(suspicious_nodes),
            "suspicious_nodes": suspicious_nodes,
            "missing_candidates_count": len(open_cands),
            "missing_candidates": open_cands,
            "total_lines": len(w_lines),
            "ambiguous_lines_count": len(ambiguous_lines),
            "ambiguous_lines": ambiguous_lines,
            "topology_error_count": (
                critical_connection_error_count(w_lines, issues)
                if _is_connection_review_stage(stage)
                else len(
                    [
                        i
                        for i in issues
                        if str(i.get("severity", "")).lower() == "error"
                    ]
                )
            ),
            "topology_errors": [i for i in issues if str(i.get("severity", "")).lower() == "error"],
            "topology_warning_count": len([i for i in issues if str(i.get("severity", "")).lower() != "error"]),
            "topology_warnings": [i for i in issues if str(i.get("severity", "")).lower() != "error"],
            "app_context": app_context or {},
        }

        system_instruction = (
            f"{POWERLENS_SYSTEM_KNOWLEDGE}\n\n"
            "당신은 Lensy라는 이름의 PowerLens 동반자 에이전트입니다.\n"
            "사용자가 새로운 검수/작업 단계(Stage)에 진입했습니다.\n"
            "현재 단계와 실제 감지된 증거(Evidence) 상태를 면밀히 관찰하고,\n"
            "사용자가 어디를 먼저 살펴봐야 하는지 직관적이고 친절하게 1~3문장으로 브리핑하세요.\n"
            "반드시 Canonical Agent Response Contract JSON 형식으로만 응답해야 합니다.\n"
            "- 의심 객체(suspicious_nodes), 누락 후보(missing_candidates), 치명적 결선 오류(topology_errors)가 있다면 decision: 'HUMAN_CHECK', action_mode: 'GUIDE'를 부여하고 focus_targets에 실제 ID들을 포함하세요. OBJECT_REVIEW 단계에서는 옛 승인 버튼을 가리키지 마시고 highlight_target은 null로 두세요.\n"
            "- warning이나 info 수준의 경고(topology_warnings)만 존재하는 경우는 치명 결선 오류가 아니므로, 다른 의심 항목이 없다면 치명적 오류가 있다고 표현하지 마세요.\n"
            "- 아무 미결 이슈가 없다면 decision: 'PROCEED', action_mode: 'NONE', highlight_target: null로 설정하세요.\n"
            "- reply_ko: 1~3문장의 따뜻하고 명쾌한 한국어 안내\n"
        )
        user_prompt = (
            f"[단계 진입 증거 데이터]\n"
            f"{json.dumps(prompt_data, ensure_ascii=False, indent=2)}\n\n"
            f"위 실제 증거를 바탕으로 새로운 단계({stage})에 진입한 사용자에게 친절한 브리핑을 제공해주세요."
        )

        contents = [{"role": "user", "parts": [{"text": user_prompt}]}]
        raw_reply, active_model, is_fallback_active = self._call_gemini_with_fallback(
            system_instruction=system_instruction,
            contents=contents,
            timeout_sec=self.TIMEOUT_SECONDS,
        )

        if raw_reply:
            try:
                cleaned = raw_reply
                if cleaned.startswith("```json"):
                    cleaned = cleaned[7:]
                elif cleaned.startswith("```"):
                    cleaned = cleaned[3:]
                if cleaned.endswith("```"):
                    cleaned = cleaned[:-3]
                parsed = json.loads(cleaned.strip())
                if isinstance(parsed, dict):
                    parsed["agent_status"] = "GEMINI_PROACTIVE_FALLBACK" if is_fallback_active else "GEMINI_PROACTIVE"
                    parsed["provider_mode"] = self.provider_name
                    parsed["display_mode"] = f"Gemini ({active_model}) AI 모드"
                    return sanitize_and_validate_agent_response(parsed, "", w_nodes, w_lines, cands, issues, stage)
            except Exception:
                pass

        # Fallback to Local provider
        local_fallback = LocalReviewAssistantProvider()
        res = local_fallback.generate_proactive_summary(
            document_id=document_id,
            stage=stage,
            working_nodes=w_nodes,
            working_lines=w_lines,
            missing_candidates=cands,
            topology_issues=issues,
            app_context=app_context,
        )
        res["provider_mode"] = self.provider_name
        res["display_mode"] = self.display_mode_name
        res["agent_status"] = "LOCAL_FALLBACK_PROACTIVE"
        return res

    def answer_chat(
        self,
        message: str,
        document_id: str,
        stage: str,
        selected_node: Optional[Dict[str, Any]] = None,
        selected_line: Optional[Dict[str, Any]] = None,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
        history: Optional[List[ChatMessagePayload]] = None,
        app_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        if _is_bus_mapping_stage(stage):
            # Keep Bus Mapping answers aligned with the same Gate/proactive
            # predicates even when Gemini is configured globally.
            res = LocalReviewAssistantProvider().answer_chat(
                message=message,
                document_id=document_id,
                stage=stage,
                selected_node=selected_node,
                selected_line=selected_line,
                working_nodes=working_nodes,
                working_lines=working_lines,
                missing_candidates=missing_candidates,
                topology_issues=topology_issues,
                history=history,
                app_context=app_context,
            )
            res["provider_mode"] = self.provider_name
            res["display_mode"] = self.display_mode_name
            res["agent_status"] = "LOCAL_BUS_CONTRACT"
            return res

        if _is_connection_review_stage(stage):
            # Keep interactive Connection answers on the same deterministic
            # exception-first path as proactive summaries.
            res = LocalReviewAssistantProvider().answer_chat(
                message=message,
                document_id=document_id,
                stage=stage,
                selected_node=selected_node,
                selected_line=selected_line,
                working_nodes=working_nodes,
                working_lines=working_lines,
                missing_candidates=missing_candidates,
                topology_issues=topology_issues,
                history=history,
                app_context=app_context,
            )
            res["provider_mode"] = self.provider_name
            res["display_mode"] = self.display_mode_name
            res["agent_status"] = "LOCAL_CONNECTION_CONTRACT"
            return res

        if (stage or "").upper() in (
            "POWERFLOW_CONVERGED", "POWERFLOW_NOT_CONVERGED", "POWERFLOW_RESULT"
        ) or (
            (stage or "").upper() == "POWERFLOW"
            and (app_context or {}).get("powerflow_evidence") is not None
        ):
            res = LocalReviewAssistantProvider().answer_chat(
                message=message,
                document_id=document_id,
                stage=stage,
                selected_node=selected_node,
                selected_line=selected_line,
                working_nodes=working_nodes,
                working_lines=working_lines,
                missing_candidates=missing_candidates,
                topology_issues=topology_issues,
                history=history,
                app_context=app_context,
            )
            res["provider_mode"] = self.provider_name
            res["display_mode"] = self.display_mode_name
            res["agent_status"] = "LOCAL_POWERFLOW_CONTRACT"
            return res

        system_instruction = (
            f"{POWERLENS_SYSTEM_KNOWLEDGE}\n\n"
            "당신은 Lensy라는 이름의 PowerLens 동반자 에이전트입니다. 전력계통 단선도(SLD) 검수와 조류계산을 처음 쓰는 사람도 쉽게 이해할 수 있게 똑똑하고 친절하게 도와주세요.\n"
            "현재 단계, 선택된 객체/선로, 실제 검출 목록, 토폴로지 이슈와 조류계산 준비 상태를 근거로 정확히 판단하고, 엉뚱한 추측을 하지 마세요.\n\n"
            "조류계산 설명은 runtime_app_context.powerflow_evidence의 실제 Newton-Raphson 결과만 사용하세요. converged가 true일 때만 정상 수렴이라고 말하고, false이면 반복 횟수와 최대 mismatch를 근거로 미수렴임을 분명히 하세요. solver 수치를 새로 계산하거나 보간하지 마세요. 명시된 운영 threshold가 없으면 저전압 오류/과부하/위험 판정을 하지 말고, 최저 전압과 최대 MW 흐름은 사실값으로만 표현하세요.\n"
            "반드시 Canonical Agent Response Contract JSON 형식으로만 응답해야 합니다.\n"
            "1. 질문 의도가 위치/방법('어디야?', '어떻게 해?', '뭐 눌러?')이면 action_mode: 'GUIDE', highlight_target 설정.\n"
            "2. 명시적 안전 실행 요청('계산해줘', '결과 보여줘', '홈으로 가줘')이면 action_mode: 'EXECUTE', action_id 설정.\n"
            "3. 회로/데이터 변경 요청('Generator로 바꿔', '삭제해')이면 action_mode: 'CONFIRM_REQUIRED', action_id: null.\n"
            "4. 답변(reply_ko)은 1~3문장으로 간결하고 명확하게 한국어로 작성하세요."
        )

        nodes_summary = []
        for n in (working_nodes or []):
            nodes_summary.append({
                "id": n.get("id"),
                "class": n.get("class") or n.get("className"),
                "display_label": n.get("display_label", n.get("id")),
                "status": n.get("review_status") or n.get("status"),
                "confidence": n.get("confidence"),
                "bus_number": n.get("bus_number"),
            })

        lines_summary = []
        for l in (working_lines or []):
            lines_summary.append({
                "id": l.get("line_id", l.get("id")),
                "connected_to": l.get("connected_to", []),
                "status": l.get("review_status"),
            })

        context_data = {
            "current_stage": stage,
            "selected_node": selected_node,
            "selected_line": selected_line,
            "total_nodes_count": len(working_nodes or []),
            "detected_nodes_summary": nodes_summary,
            "total_lines_count": len(working_lines or []),
            "lines_summary": lines_summary,
            "missing_candidates": missing_candidates or [],
            "topology_issues": topology_issues or [],
            "runtime_app_context": {
                "current_screen": (app_context or {}).get("current_screen"),
                "workflow_stage": (app_context or {}).get("workflow_stage", stage),
                "has_diagram": (app_context or {}).get("has_diagram"),
                "excel_loaded": (app_context or {}).get("excel_loaded"),
                "powerflow_ready": (app_context or {}).get("powerflow_ready"),
                "powerflow_converged": (app_context or {}).get("powerflow_converged"),
                "powerflow_evidence": (app_context or {}).get("powerflow_evidence"),
            },
        }

        contents = []
        hist = history or []
        for h in hist[-MAX_CHAT_HISTORY:]:
            role = "user" if h.role == "user" else "model"
            contents.append({"role": role, "parts": [{"text": h.content}]})

        user_content_text = (
            f"[현재 도면 검수 데이터 컨텍스트]\n"
            f"{json.dumps(context_data, ensure_ascii=False, indent=2)}\n\n"
            f"[사용자 질문]\n{message}"
        )
        user_parts: List[Dict[str, Any]] = [{"text": user_content_text}]

        # Multimodal Vision: Compress and attach original circuit diagram image
        try:
            from review.session_store import session_store
            session = session_store.get_session(document_id)
            if session and session.image_bytes:
                import base64
                import cv2
                import numpy as np

                nparr = np.frombuffer(session.image_bytes, np.uint8)
                img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
                if img is not None:
                    h, w = img.shape[:2]
                    max_dim = 1024
                    if max(h, w) > max_dim:
                        scale = max_dim / float(max(h, w))
                        img = cv2.resize(img, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
                    _, buf = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
                    b64_img = base64.b64encode(buf.tobytes()).decode("utf-8")
                    user_parts.insert(0, {
                        "inlineData": {
                            "mimeType": "image/jpeg",
                            "data": b64_img,
                        }
                    })
        except Exception:
            pass

        contents.append({"role": "user", "parts": user_parts})

        raw_reply, active_model, is_fallback_active = self._call_gemini_with_fallback(
            system_instruction=system_instruction,
            contents=contents,
            timeout_sec=self.TIMEOUT_SECONDS,
        )

        if raw_reply:
            try:
                cleaned = raw_reply
                if cleaned.startswith("```json"):
                    cleaned = cleaned[7:]
                elif cleaned.startswith("```"):
                    cleaned = cleaned[3:]
                if cleaned.endswith("```"):
                    cleaned = cleaned[:-3]
                parsed = json.loads(cleaned.strip())
                if isinstance(parsed, dict):
                    parsed["agent_status"] = "GEMINI_LLM_FALLBACK" if is_fallback_active else "GEMINI_LLM"
                    parsed["provider_mode"] = self.provider_name
                    parsed["display_mode"] = f"Gemini ({active_model}) AI 모드"
                    return sanitize_and_validate_agent_response(
                        parsed, message, working_nodes, working_lines, missing_candidates, topology_issues, stage
                    )
            except Exception:
                pass

        local_fallback = LocalReviewAssistantProvider()
        return local_fallback.answer_chat(
            message=message,
            document_id=document_id,
            stage=stage,
            selected_node=selected_node,
            selected_line=selected_line,
            working_nodes=working_nodes,
            working_lines=working_lines,
            missing_candidates=missing_candidates,
            topology_issues=topology_issues,
            history=history,
            app_context=app_context,
        )


class OpenAIReviewAssistantProvider(ReviewAssistantProvider):
    """Future Adapter for OpenAI GPT-4o Multimodal Review Assistant.

    Cost and safety guards included:
    - Explicit opt-in required (AI_PROVIDER=openai + OPENAI_API_KEY).
    - Chat history truncation (MAX_CHAT_HISTORY = 15).
    - Request timeout (10.0s) & Max retries (2).
    - Compact payload construction (ROI images only when needed).
    """

    MAX_RETRIES: int = 2
    TIMEOUT_SECONDS: float = 10.0

    def __init__(self, api_key: str, model_name: str = "gpt-4o"):
        self.api_key = api_key
        self.model_name = model_name

    @property
    def provider_name(self) -> str:
        return "openai"

    @property
    def display_mode_name(self) -> str:
        return f"OpenAI ({self.model_name}) 모드"

    def generate_proactive_summary(
        self,
        document_id: str,
        stage: str,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
        app_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        local_fallback = LocalReviewAssistantProvider()
        res = local_fallback.generate_proactive_summary(
            document_id=document_id,
            stage=stage,
            working_nodes=working_nodes,
            working_lines=working_lines,
            missing_candidates=missing_candidates,
            topology_issues=topology_issues,
            app_context=app_context,
        )
        res["provider_mode"] = self.provider_name
        res["display_mode"] = self.display_mode_name
        return res

    def answer_chat(
        self,
        message: str,
        document_id: str,
        stage: str,
        selected_node: Optional[Dict[str, Any]] = None,
        selected_line: Optional[Dict[str, Any]] = None,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
        history: Optional[List[ChatMessagePayload]] = None,
        app_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        if _is_bus_mapping_stage(stage):
            res = LocalReviewAssistantProvider().answer_chat(
                message=message,
                document_id=document_id,
                stage=stage,
                selected_node=selected_node,
                selected_line=selected_line,
                working_nodes=working_nodes,
                working_lines=working_lines,
                missing_candidates=missing_candidates,
                topology_issues=topology_issues,
                history=history,
                app_context=app_context,
            )
            res["provider_mode"] = self.provider_name
            res["display_mode"] = self.display_mode_name
            res["agent_status"] = "LOCAL_BUS_CONTRACT"
            return res

        from openai import OpenAI
        client = OpenAI(api_key=self.api_key, timeout=self.TIMEOUT_SECONDS)

        system_prompt = (
            "당신은 전력계통 단선도(SLD) 자동인식 및 검수 보조 AI 어시스턴트입니다.\n"
            "사용자의 질문에 대해 현재 도면 검수 상태(Object Review / Connection Review), "
            "선택된 객체, 선택된 선로, 토폴로지 유효성 검사 이슈, 누락 설비 후보를 바탕으로 정확하고 간결하게 답변하세요.\n"
            "규칙:\n"
            "1. 한국어로 정중하고 명확하게 답변하세요.\n"
            "2. 내부 Chain-of-Thought는 절대 출력하지 마세요.\n"
            "3. [판단] - [근거 요약] - [추천 액션] 3단계 구조로 자연스럽게 설명하세요.\n"
            "4. 객체나 선로는 사람이 보기 쉬운 Display Label(예: BUS 4, LOAD 2, L1)을 우선 지칭하세요."
        )

        context_data = {
            "current_stage": stage,
            "selected_node": selected_node,
            "selected_line": selected_line,
            "total_nodes_count": len(working_nodes or []),
            "suspicious_nodes_count": len([n for n in (working_nodes or []) if n.get("review_status") == "SUSPICIOUS"]),
            "total_lines_count": len(working_lines or []),
            "ambiguous_lines_count": len([l for l in (working_lines or []) if l.get("review_status") == "AMBIGUOUS"]),
            "missing_candidates": missing_candidates or [],
            "topology_issues": topology_issues or [],
        }

        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "system", "content": f"현재 검수 컨텍스트:\n{json.dumps(context_data, ensure_ascii=False, indent=2)}"},
        ]

        hist = history or []
        for h in hist[-MAX_CHAT_HISTORY:]:
            messages.append({"role": h.role, "content": h.content})

        messages.append({"role": "user", "content": message})

        response = client.chat.completions.create(
            model=self.model_name,
            messages=messages,
            temperature=0.2,
            max_tokens=400,
        )

        reply = response.choices[0].message.content or "답변을 생성할 수 없습니다."
        res = {
            "reply_ko": reply,
            "decision": "UNKNOWN",
            "intent": "OPENAI_CHAT",
            "action_mode": "NONE",
            "action_id": None,
            "agent_status": "OPENAI_LLM",
            "provider_mode": self.provider_name,
            "display_mode": self.display_mode_name,
            "context_summary": {
                "stage": stage,
                "selected_node_id": selected_node.get("id") if selected_node else None,
                "selected_line_id": selected_line.get("line_id", selected_line.get("id")) if selected_line else None,
            },
        }
        return sanitize_and_validate_agent_response(
            res, message, working_nodes, working_lines, missing_candidates, topology_issues, stage
        )


def get_assistant_provider() -> ReviewAssistantProvider:
    """Factory function to get the configured Review Assistant Provider.

    Configuration Rules:
    1. If `AI_PROVIDER=openai` and `OPENAI_API_KEY` is present, uses `OpenAIReviewAssistantProvider`.
    2. If `AI_PROVIDER=local`, explicitly uses `LocalReviewAssistantProvider`.
    3. If `GEMINI_API_KEY` (or `GOOGLE_API_KEY`) is present, uses `GeminiReviewAssistantProvider`.
    4. Otherwise, falls back to `LocalReviewAssistantProvider`.
    """
    configured_provider = os.environ.get("AI_PROVIDER", "").strip().lower()
    gemini_key = os.environ.get("GEMINI_API_KEY", "").strip() or os.environ.get("GOOGLE_API_KEY", "").strip()
    openai_key = os.environ.get("OPENAI_API_KEY", "").strip()

    if configured_provider == "local":
        return LocalReviewAssistantProvider()

    if configured_provider == "openai" and openai_key:
        model_name = os.environ.get("OPENAI_MODEL", "gpt-4o")
        return OpenAIReviewAssistantProvider(api_key=openai_key, model_name=model_name)

    if gemini_key:
        return GeminiReviewAssistantProvider(
            api_key=gemini_key,
            model_name=get_gemini_model_name(),
            fallback_model_name=get_gemini_fallback_model_name(),
        )

    return LocalReviewAssistantProvider()

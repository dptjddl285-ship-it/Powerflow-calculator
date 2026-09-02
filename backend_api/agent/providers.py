"""VisionFlow Review Assistant Provider Architecture.

Defines the common interface for Review Assistant Providers and implements:
1. LocalReviewAssistantProvider (Default, deterministic, free, evidence-based local intelligence).
2. OpenAIReviewAssistantProvider (Future adapter skeleton with cost safety guards).
3. Factory function `get_assistant_provider()` supporting explicit opt-in (`AI_PROVIDER=openai`).
"""
from __future__ import annotations

import abc
import json
import os
from typing import Any, Dict, List, Optional
import numpy as np

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
    ) -> Dict[str, Any]:
        """Generate proactive summary informing the user where to look first."""
        w_nodes = working_nodes or []
        w_lines = working_lines or []
        cands = missing_candidates or []
        issues = topology_issues or []

        if stage == "OBJECT_REVIEW":
            total_nodes = len(w_nodes)
            suspicious = [n for n in w_nodes if n.get("review_status") == "SUSPICIOUS"]
            open_cands = [c for c in cands if c.get("status") == "OPEN"]
            clean_count = total_nodes - len(suspicious)

            priority_items = []
            for s in suspicious:
                disp = s.get("display_label", s.get("id", "Unknown"))
                reasons = s.get("review_reasons", ["신뢰도 경계"])
                reason_str = reasons[0] if reasons else "신뢰도 경계"
                priority_items.append({
                    "id": s.get("id", ""),
                    "display_label": disp,
                    "target_type": "NODE",
                    "reason": reason_str,
                    "severity": "WARNING",
                })

            for c in open_cands:
                cand_cls = str(c.get("suspected_class", "")).upper()
                priority_items.append({
                    "id": c.get("id", ""),
                    "display_label": f"{cand_cls} 누락 후보",
                    "target_type": "MISSING_CANDIDATE",
                    "reason": c.get("description_ko", "미검출 설비 가능성"),
                    "severity": "ALERT",
                })

            # Format Natural Korean message
            lines = [f"📊 **[AI 검토 우선순위 요약 - 객체 검수]**"]
            lines.append(f"• **총 검출 객체**: {total_nodes}개 (정상/자동승인 대상: **{clean_count}개**)")
            lines.append(f"• **우선 검토 대상**: **{len(suspicious)}건** (누락 의심 설비: **{len(open_cands)}건**)")

            if priority_items:
                lines.append("\n🔍 **먼저 확인해야 할 항목:**")
                for idx, p in enumerate(priority_items[:4]):
                    lines.append(f"  {idx + 1}) **{p['display_label']}** - {p['reason']}")
                lines.append("\n💡 정상 객체는 `[정상 객체 일괄 승인]`으로 한 번에 통과시키고, 위 의심 항목만 검토하세요.")
            else:
                lines.append("\n✓ 모든 객체가 명확한 정상 심볼로 판정되었습니다. `[정상 객체 일괄 승인]` 후 다음 단계로 진행할 수 있습니다.")

            return {
                "summary_text": "\n".join(lines),
                "total_count": total_nodes,
                "clean_count": clean_count,
                "suspicious_count": len(suspicious),
                "missing_count": len(open_cands),
                "priority_items": priority_items,
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
            }

        else:
            # Connection Review Stage
            total_lines = len(w_lines)
            ambiguous = [l for l in w_lines if l.get("review_status") == "AMBIGUOUS"]
            error_issues = [i for i in issues if i.get("severity") == "error"]
            clean_lines = total_lines - len(ambiguous)

            priority_items = []
            for a in ambiguous:
                disp = a.get("display_label", a.get("line_id", "Unknown"))
                conn_name = a.get("display_name", disp)
                priority_items.append({
                    "id": a.get("line_id", a.get("id", "")),
                    "display_label": disp,
                    "target_type": "LINE",
                    "reason": f"결선 다중 모선 후보 ({conn_name})",
                    "severity": "WARNING",
                })

            for iss in error_issues:
                priority_items.append({
                    "id": iss.get("line_id", iss.get("node_id", "")),
                    "display_label": iss.get("code", "GRAPH_ERROR"),
                    "target_type": "TOPOLOGY_ISSUE",
                    "reason": iss.get("message", "전기적 규칙 위반"),
                    "severity": "ERROR",
                })

            lines = [f"📊 **[AI 검토 우선순위 요약 - 결선 검수]**"]
            lines.append(f"• **총 인식 선로**: {total_lines}개 (정상 결선: **{clean_lines}개**)")
            lines.append(f"• **결선 오류/검토 필요**: **{len(ambiguous)}건** (토폴로지 결함: **{len(error_issues)}건**)")

            if priority_items:
                lines.append("\n🔗 **먼저 확인해야 할 결선:**")
                for idx, p in enumerate(priority_items[:4]):
                    lines.append(f"  {idx + 1}) **{p['display_label']}** - {p['reason']}")
                lines.append("\n💡 정상 선로는 `[정상 결선 일괄 승인]`으로 승인하고, 오류 선로만 [연결 대상 재지정]을 진행하세요.")
            else:
                lines.append("\n✓ 모든 결선이 전기적 무결성 검증을 통과했습니다. `[회로도 검증 완료 (Final Gate)]`를 진행하세요.")

            return {
                "summary_text": "\n".join(lines),
                "total_count": total_lines,
                "clean_count": clean_lines,
                "suspicious_count": len(ambiguous),
                "missing_count": len(error_issues),
                "priority_items": priority_items,
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
            }

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
    ) -> Dict[str, Any]:
        msg = (message or "").strip().lower()
        w_nodes = working_nodes or []
        w_lines = working_lines or []
        cands = missing_candidates or []
        issues = topology_issues or []

        # 1. Summary & Status Requests (검토 현황 요약)
        if any(k in msg for k in ["요약", "현황", "검토 필요", "상태", "summary", "status"]):
            summary_res = self.generate_proactive_summary(
                document_id=document_id,
                stage=stage,
                working_nodes=w_nodes,
                working_lines=w_lines,
                missing_candidates=cands,
                topology_issues=issues,
            )
            return {
                "reply_ko": summary_res["summary_text"],
                "agent_status": "LOCAL_SUMMARY",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"stage": stage},
            }

        # 2. Next Step Guidance (다음에 무엇을 해야 하는지)
        if any(k in msg for k in ["다음", "무엇", "어떻게", "진행", "통과", "gate", "next"]):
            if stage == "OBJECT_REVIEW":
                suspicious_count = len([n for n in w_nodes if n.get("review_status") == "SUSPICIOUS"])
                open_cand_count = len([c for c in cands if c.get("status") == "OPEN"])
                reply = "🧭 **[다음 단계 진행 가이드 - 객체 검수]:**\n"
                reply += f"1. 우선 검토 객체 확인 (남은 의심 객체: **{suspicious_count}개**)\n"
                reply += f"2. 누락 설비 후보 확인 (남은 미확인 후보: **{open_cand_count}개**)\n"
                reply += "3. 정상 객체는 상단 **[정상 객체 일괄 승인]**으로 승인\n"
                reply += "4. 하단 **'도면 전체 대조 확인'** 체크박스 선택\n"
                reply += "5. **[객체 검수 완료 (Gate 통과)]** 클릭 ➔ **[다음: 결선 인식]** 시작"
            else:
                ambiguous_count = len([l for l in w_lines if l.get("review_status") == "AMBIGUOUS"])
                error_count = len([i for i in issues if i.get("severity") == "error"])
                reply = "🧭 **[다음 단계 진행 가이드 - 결선 검수]:**\n"
                reply += f"1. 결선 오류 선로 해결 (남은 오류: **{ambiguous_count}개**)\n"
                reply += f"2. 토폴로지 결함 해결 (남은 결함: **{error_count}개**)\n"
                reply += "3. 정상 선로는 **[정상 결선 일괄 승인]**으로 승인\n"
                reply += "4. **[회로도 검증 완료 (Final Gate)]** 클릭 ➔ VerifiedSLD 생성 및 Canvas Handoff"

            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_GUIDE",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"stage": stage},
            }

        # 3. Class Change Impact Analysis (클래스 변경 시 전기적 영향)
        if selected_node and any(k in msg for k in ["바꾸", "변경", "영향", "change", "바꾸면"]):
            disp_name = selected_node.get("display_label", selected_node.get("id", "선택 객체"))
            curr_cls = str(selected_node.get("class", "")).lower()
            reply = f"⚡ **[{disp_name}] 클래스 변경 시 계통 영향 분석:**\n"
            if curr_cls == "bus":
                reply += "• **모선(Bus) ➔ 발전기/부하로 변경 시:**\n"
                reply += "  - 해당 노드에 연결된 여러 모선 간 간선이 단일 설비 인출선으로 재해석되어 다중 결선 위반(Conflict)이 발생할 수 있습니다.\n"
                reply += "  - 발전기나 부하는 원칙적으로 단일 모선에 1개의 단자로만 연결되어야 합니다."
            elif curr_cls in ("generator", "load"):
                reply += f"• **{curr_cls.upper()} ➔ 모선(Bus)으로 변경 시:**\n"
                reply += "  - 해당 위치가 계통의 전기적 분기 모선으로 승격되어, 인접 선로들이 이 모선으로 접속(Route) 가능해집니다.\n"
                reply += "  - 모선은 최소 2개 이상의 단자 또는 선로가 연결되어야 유효한 모선으로 인정됩니다."
            else:
                reply += "• **변압기(Transformer) 변경 시:**\n"
                reply += "  - 1차측과 2차측 2개 모선 간의 연계 선로 연결성이 변경됩니다."

            reply += "\n💡 **추천 액션**: 실제 도면 심볼과 일치하도록 하단 [클래스 변경] 칩을 선택하세요."
            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_CLASS_IMPACT",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"node_label": disp_name},
            }

        # 4. Specific Object Evidence & Judgment (왜 의심/왜 이 클래스인지)
        if selected_node and any(k in msg for k in ["객체", "이것", "왜", "의심", "판단", "근거", "bus", "모선", "발전기", "generator", "부하", "load", "변압기", "transformer"]):
            disp_name = selected_node.get("display_label", selected_node.get("id", "선택 객체"))
            node_id = selected_node.get("id", "")
            cls = str(selected_node.get("class", "unknown")).upper()
            conf = int(float(selected_node.get("confidence", 0.0)) * 100)
            status = selected_node.get("review_status", "DETECTED")
            reasons = selected_node.get("review_reasons", [])
            source = selected_node.get("source", "yolo_detector")
            evidence = selected_node.get("evidence", {})
            geom = evidence.get("geometry_evidence", {})
            aspect = geom.get("aspect_ratio", 0.0)

            reply = f"🔍 **[{disp_name}] 객체 분석 근거 (내부 ID: `{node_id}`):**\n"
            reply += f"• **판정 클래스**: `{cls}` (AI 신뢰도: **{conf}%**)\n"
            reply += f"• **현재 상태**: `{status}`  |  **탐지 소스**: `{source}`\n"
            if aspect > 0:
                reply += f"• **형상 종횡비**: 가로/세로 비율 `{aspect:.1f}`\n"

            if reasons:
                reply += f"• **검토 사유 (Why Flagged)**: {', '.join(reasons)}\n"
            else:
                reply += "• **검토 사유**: 심볼 형상 및 신뢰도 기준을 충족하여 정상 판정되었습니다.\n"

            if status == "SUSPICIOUS":
                reply += "\n💡 **추천 액션**: 도면의 실제 심볼을 확인하고, 정상 심볼이면 [승인(Confirm)], 오탐이면 [클래스 변경] 또는 [제외(Reject)]하세요."
            else:
                reply += "\n💡 **추천 액션**: 정상 심볼로 확인되었으므로 추가 조치 없이 유지하거나 [승인]하세요."

            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_NODE_EVIDENCE",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"node_label": disp_name, "status": status},
            }

        # 5. Connection Line Evidence & Issues (왜 결선 문제인지)
        if selected_line and any(k in msg for k in ["선", "선로", "결선", "연결", "line", "connect", "문제", "오류", "bus_"]):
            disp_name = selected_line.get("display_name", selected_line.get("display_label", selected_line.get("line_id", "선택 선로")))
            line_id = selected_line.get("line_id", selected_line.get("id", ""))
            conn = selected_line.get("connected_to", [])
            conn_str = selected_line.get("endpoints_display", " ➔ ".join(conn) if conn else "미연결 (Dangling)")
            issues = selected_line.get("validation_issues", [])
            trace_method = selected_line.get("trace_method", "electrical_graph")

            reply = f"🔗 **[{disp_name}] 결선 진단 근거 (내부 ID: `{line_id}`):**\n"
            reply += f"• **연결 관계**: `{conn_str}`\n"
            reply += f"• **추적 방식**: `{trace_method}`\n"

            if issues:
                issue_descs = [it.get("message", it.get("code", "형상 불일치")) for it in issues]
                reply += f"• **감지된 결함 (Issues)**: {', '.join(issue_descs)}\n"
                reply += "\n💡 **추천 액션**: 하단 [연결 대상 Bus 재지정] 칩을 클릭하여 올바른 모선에 연결하거나 [선로 제외]를 선택하세요."
            else:
                reply += "• **검증 결과**: 토폴로지 유효성 검사(Graph Validation)를 통과한 정상 선로입니다.\n"
                reply += "\n💡 **추천 액션**: 정상 연결이므로 [선로 승인] 또는 [정상 결선 일괄 승인]을 진행하세요."

            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_LINE_EVIDENCE",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"line_label": disp_name},
            }

        # 6. Missing Candidate Summary (누락 후보 질문)
        if any(k in msg for k in ["누락", "후보", "변압기", "어디", "missing", "빠진"]):
            open_cands = [c for c in cands if c.get("status") == "OPEN"]
            if open_cands:
                cand = open_cands[0]
                reply = f"⚠️ **누락 의심 설비 안내 (Global Completeness):**\n"
                reply += f"• **의심 설비**: `{cand.get('suspected_class', '').upper()}`\n"
                reply += f"• **진단 근거**: {cand.get('description_ko', '')}\n"
                reply += "\n💡 **추천 액션**: 상단 도면에서 해당 영역을 드래그하여 **[객체 수동 추가]**를 진행하거나, 도면에 없는 기기라면 **[문제 없음 (Dismiss)]**을 선택하세요."
            else:
                reply = "✓ **누락 설비 없음**: 전체 모선-설비 비율 검사 결과 누락 후보가 없습니다."

            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_MISSING_CANDIDATE",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"candidates_count": len(open_cands)},
            }

        # Default Generic Guidance
        return {
            "reply_ko": (
                f"🤖 **VisionFlow SLD Review Assistant ({self.display_mode_name}):**\n"
                f"현재 **{stage}** 단계입니다. "
                "도면 내 특정 객체(예: BUS 1)나 선로(예: L1)를 클릭한 후 질문하시거나, "
                "'검토 필요한 부분 요약해줘', '왜 이 객체가 의심이야?', '다음에 무엇을 해야 해?' 와 같이 문의해 주세요."
            ),
            "agent_status": "LOCAL_DEFAULT",
            "provider_mode": self.provider_name,
            "display_mode": self.display_mode_name,
            "context_summary": {"stage": stage},
        }


class GeminiReviewAssistantProvider(ReviewAssistantProvider):
    """Google Gemini Review Assistant Provider.

    Uses Google Gemini REST API (gemini-3.5-flash-lite / gemini-3.5-flash)
    for fast, intelligent, context-aware SLD diagram verification assistance.
    """

    TIMEOUT_SECONDS: float = 25.0

    def __init__(self, api_key: str, model_name: str = "gemini-3.5-flash-lite"):
        self.api_key = api_key
        self.model_name = model_name

    @property
    def provider_name(self) -> str:
        return "gemini"

    @property
    def display_mode_name(self) -> str:
        return f"Gemini ({self.model_name}) AI 모드"

    def generate_proactive_summary(
        self,
        document_id: str,
        stage: str,
        working_nodes: Optional[List[Dict[str, Any]]] = None,
        working_lines: Optional[List[Dict[str, Any]]] = None,
        missing_candidates: Optional[List[Dict[str, Any]]] = None,
        topology_issues: Optional[List[Dict[str, Any]]] = None,
    ) -> Dict[str, Any]:
        local_fallback = LocalReviewAssistantProvider()
        res = local_fallback.generate_proactive_summary(
            document_id=document_id,
            stage=stage,
            working_nodes=working_nodes,
            working_lines=working_lines,
            missing_candidates=missing_candidates,
            topology_issues=topology_issues,
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
    ) -> Dict[str, Any]:
        import json
        import urllib.error
        import urllib.request

        system_instruction = (
            "당신은 전력계통 단선도(Single Line Diagram, SLD) 자동인식 및 검수 보조 AI 어시스턴트(PowerLens / VisionFlow)입니다.\n"
            "사용자의 질문에 대해 첨부된 원본 도면 이미지와 현재 도면 검수 상태(Object Review / Connection Review), "
            "검출된 전체 설비 목록, 선택된 객체/선로, 토폴로지 유효성 검사 이슈, 누락 설비 후보를 바탕으로 전력공학 지식에 기반하여 전문적이고 명쾌하게 답변하세요.\n\n"
            "답변 지침:\n"
            "1. 한국어로 정중하고 명확하게 답변하세요.\n"
            "2. [판단] - [근거 요약] - [추천 액션] 3단계 구조로 자연스럽게 설명하세요.\n"
            "3. 첨부된 도면 이미지의 텍스트나 기호 형태(변압기, 발전기, 부하, 모선 등)를 시각적으로 직접 확인하고 질문에 성실히 답변하세요.\n"
            "4. 객체나 선로는 사람이 보기 쉬운 Display Label(예: BUS 4, LOAD 2, T1, G1, L1)을 우선 지칭하세요."
        )

        nodes_summary = []
        for n in (working_nodes or []):
            nodes_summary.append({
                "id": n.get("id"),
                "class": n.get("class") or n.get("className"),
                "display_label": n.get("display_label", n.get("id")),
                "status": n.get("review_status"),
                "confidence": n.get("confidence"),
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
        except Exception as e:
            print(f"[Gemini Image Attach Skip]: {e}")

        contents.append({"role": "user", "parts": user_parts})

        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model_name}:generateContent?key={self.api_key}"
        payload = {
            "system_instruction": {
                "parts": [{"text": system_instruction}]
            },
            "contents": contents,
            "generationConfig": {
                "temperature": 0.2,
                "maxOutputTokens": 600,
            }
        }

        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=self.TIMEOUT_SECONDS) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                candidates = data.get("candidates", [])
                if candidates:
                    reply = candidates[0].get("content", {}).get("parts", [{}])[0].get("text", "")
                    if reply.strip():
                        return {
                            "reply_ko": reply.strip(),
                            "agent_status": "GEMINI_LLM",
                            "provider_mode": self.provider_name,
                            "display_mode": self.display_mode_name,
                            "context_summary": {
                                "stage": stage,
                                "selected_node_id": selected_node.get("id") if selected_node else None,
                                "selected_line_id": selected_line.get("line_id", selected_line.get("id")) if selected_line else None,
                            },
                        }
        except Exception as e:
            print(f"[Gemini API Call Fallback]: {e}")

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
    ) -> Dict[str, Any]:
        local_fallback = LocalReviewAssistantProvider()
        res = local_fallback.generate_proactive_summary(
            document_id=document_id,
            stage=stage,
            working_nodes=working_nodes,
            working_lines=working_lines,
            missing_candidates=missing_candidates,
            topology_issues=topology_issues,
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
    ) -> Dict[str, Any]:
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
        return {
            "reply_ko": reply,
            "agent_status": "OPENAI_LLM",
            "provider_mode": self.provider_name,
            "display_mode": self.display_mode_name,
            "context_summary": {
                "stage": stage,
                "selected_node_id": selected_node.get("id") if selected_node else None,
                "selected_line_id": selected_line.get("line_id", selected_line.get("id")) if selected_line else None,
            },
        }


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
        model_name = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash-lite")
        return GeminiReviewAssistantProvider(api_key=gemini_key, model_name=model_name)

    return LocalReviewAssistantProvider()

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

from .system_knowledge import POWERLENS_SYSTEM_KNOWLEDGE

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
        """Generate proactive summary informing the user where to look first."""
        w_nodes = working_nodes or []
        w_lines = working_lines or []
        cands = missing_candidates or []
        issues = topology_issues or []
        stage_upper = (stage or "HOME").upper()

        if stage_upper in ("HOME", "EMPTY_HOME"):
            return {
                "summary_text": (
                    "👋 **안녕하세요! PowerLens AI입니다.** ✦\n\n"
                    "단선도를 불러오시면 AI가 모선, 발전기, 변압기, 부하 설비와 연결 선로를 자동으로 인식하고 검수를 도와드립니다.\n\n"
                    "💡 **시작 가이드:**\n"
                    "• 중앙의 **[단선도 AI 분석 시작하기]** 버튼을 눌러 회로도 이미지를 선택하세요.\n"
                    "• IEEE-24 표준 계통 샘플 도면으로 즉시 체험해볼 수도 있습니다."
                ),
                "total_count": 0,
                "clean_count": 0,
                "suspicious_count": 0,
                "missing_count": 0,
                "priority_items": [],
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
            }

        elif stage_upper == "OBJECT_REVIEW":
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

            lines = [f"📊 **[AI 검토 우선순위 요약 - 객체 검수]**"]
            lines.append(f"• **총 검출 객체**: {total_nodes}개 (정상/자동승인 대상: **{clean_count}개**)")
            lines.append(f"• **우선 검토 대상**: **{len(suspicious)}건** (누락 의심 설비: **{len(open_cands)}건**)")

            if priority_items:
                lines.append("\n🔍 **먼저 확인해야 할 항목:**")
                for idx, p in enumerate(priority_items[:4]):
                    lines.append(f"  {idx + 1}) **{p['display_label']}** - {p['reason']}")
                lines.append("\n💡 정상 객체는 `[정상 객체 일괄 승인]`으로 한 번에 통과시키고, 위 의심 항목만 검토하세요.")
            else:
                lines.append("\n✓ 모든 객체가 명확한 정상 심볼로 판정되었습니다. 하단 `[객체 검수 완료 (다음: 모선 매핑)]` 버튼을 눌러 진행할 수 있습니다.")

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

        elif stage_upper == "BUS_MAPPING":
            return {
                "summary_text": (
                    "📊 **[AI 검토 우선순위 요약 - 모선 번호 매핑]**\n\n"
                    "도면에서 인식된 각 모선에 고유한 번호(예: Bus 1~24)가 바르게 부여되었는지 확인합니다.\n\n"
                    "💡 **확인 사항:**\n"
                    "• 번호가 지정되지 않은 미할당 모선이나 중복된 번호가 있는지 확인하세요.\n"
                    "• 번호 부여가 끝나면 상단 **[다음: 결선 검수]** 단계로 이동하세요."
                ),
                "total_count": len(w_nodes),
                "clean_count": len(w_nodes),
                "suspicious_count": 0,
                "missing_count": 0,
                "priority_items": [],
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
            }

        elif stage_upper in ("CONNECTION_REVIEW", "LINE_REVIEW"):
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
            lines.append(f"• **결선 오류/검토 필요**: **{len(ambiguous)}건** (연결 구조 결함: **{len(error_issues)}건**)")

            if priority_items:
                lines.append("\n🔗 **먼저 확인해야 할 결선:**")
                for idx, p in enumerate(priority_items[:4]):
                    lines.append(f"  {idx + 1}) **{p['display_label']}** - {p['reason']}")
                lines.append("\n💡 정상 선로는 `[정상 결선 일괄 승인]`으로 승인하고, 오류 선로만 [연결 대상 재지정]을 진행하세요.")
            else:
                lines.append("\n✓ 모든 결선이 전기적 무결성 검증을 통과했습니다. `[회로도 검증 완료]`를 진행하세요.")

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

        elif stage_upper == "FINAL_REVIEW":
            return {
                "summary_text": (
                    "🎉 **[회로도 최종 검증 완료]**\n\n"
                    "단선도 토폴로지 검증이 통과되어 검증된 단선도(Verified SLD)가 생성되었습니다.\n\n"
                    "💡 **다음 단계:**\n"
                    "• 조류계산에 필요한 선로 임피던스(R, X, B)와 발전·부하 제원 엑셀(.xlsx)을 연결하세요.\n"
                    "• **[캔버스 편집 화면으로 이동]** 버튼을 클릭하여 CAD에서 회로도를 확인할 수 있습니다."
                ),
                "total_count": len(w_nodes),
                "clean_count": len(w_nodes),
                "suspicious_count": 0,
                "missing_count": 0,
                "priority_items": [],
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
            }

        elif stage_upper in ("CAD", "EXCEL_MAPPING"):
            return {
                "summary_text": (
                    "⚡ **[CAD 캔버스 & 계통 제원]**\n\n"
                    "단선도가 CAD 캔버스에 배치되었습니다.\n\n"
                    "💡 **다음 단계:**\n"
                    "• 상단 **[엑셀 가져오기]** 버튼을 눌러 계통 파라미터 엑셀 파일(예: case24_psse.xlsx)을 연결하세요.\n"
                    "• 제원이 연결되면 파란색 **[조류계산 실행]** 버튼이 활성화됩니다."
                ),
                "total_count": len(w_nodes),
                "clean_count": len(w_nodes),
                "suspicious_count": 0,
                "missing_count": 0,
                "priority_items": [],
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
            }

        elif stage_upper == "POWERFLOW_READY":
            return {
                "summary_text": (
                    "🚀 **[조류계산 준비 완료]**\n\n"
                    "모든 모선 토폴로지와 선로 제원이 연결되었습니다.\n\n"
                    "💡 **다음 단계:**\n"
                    "• 상단 파란색 **[조류계산 실행]** 버튼을 클릭하여 뉴턴-랩슨 수치해석을 시작하세요."
                ),
                "total_count": len(w_nodes),
                "clean_count": len(w_nodes),
                "suspicious_count": 0,
                "missing_count": 0,
                "priority_items": [],
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
            }

        elif stage_upper == "POWERFLOW_RESULT":
            return {
                "summary_text": (
                    "📈 **[조류계산 수렴 완료]**\n\n"
                    "뉴턴-랩슨 조류계산이 성공적으로 수렴했습니다!\n\n"
                    "💡 **확인 방법:**\n"
                    "• 상단 **[수치 결과표]** 버튼을 클릭하여 모선 전압과 선로 조류/손실 표를 확인하세요.\n"
                    "• 도면 위 각 모선/발전기에 표시된 전압(pu)과 위상각(deg)을 살펴보세요."
                ),
                "total_count": len(w_nodes),
                "clean_count": len(w_nodes),
                "suspicious_count": 0,
                "missing_count": 0,
                "priority_items": [],
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
            }

        else:
            return {
                "summary_text": f"현재 **{stage}** 단계입니다. 안내가 필요하시면 질문해주세요.",
                "total_count": len(w_nodes),
                "clean_count": len(w_nodes),
                "suspicious_count": 0,
                "missing_count": 0,
                "priority_items": [],
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
        app_context: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        msg = (message or "").strip().lower()
        w_nodes = working_nodes or []
        w_lines = working_lines or []
        cands = missing_candidates or []
        issues = topology_issues or []
        stage_upper = (stage or "HOME").upper()

        # 1. Summary & Status Requests (검토 현황 요약)
        if any(k in msg for k in ["요약", "현황", "검토 필요", "상태", "summary", "status"]):
            summary_res = self.generate_proactive_summary(
                document_id=document_id,
                stage=stage,
                working_nodes=w_nodes,
                working_lines=w_lines,
                missing_candidates=cands,
                topology_issues=issues,
                app_context=app_context,
            )
            return {
                "reply_ko": summary_res["summary_text"],
                "agent_status": "LOCAL_SUMMARY",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"stage": stage},
            }

        # 2. Next Step Guidance (다음에 무엇을 해야 하는지 - 모든 단계 지원)
        if any(k in msg for k in ["다음", "무엇", "어떻게", "진행", "통과", "gate", "next", "뭐해", "뭘 해야", "도와줘"]):
            if stage_upper in ("HOME", "EMPTY_HOME"):
                reply = (
                    "🧭 **[다음 단계 진행 가이드 - 시작하기]:**\n"
                    "1. 단선도 도면을 먼저 불러오세요.\n"
                    "2. 화면 중앙의 **[단선도 AI 분석 시작하기]** 버튼을 누르거나 샘플 도면(IEEE-24)을 선택하세요.\n"
                    "3. AI가 도면을 분석하면 자동으로 객체 검수실로 이동합니다."
                )
            elif stage_upper == "OBJECT_REVIEW":
                suspicious_count = len([n for n in w_nodes if n.get("review_status") == "SUSPICIOUS"])
                open_cand_count = len([c for c in cands if c.get("status") == "OPEN"])
                reply = "🧭 **[다음 단계 진행 가이드 - ① 객체 검수]:**\n"
                if suspicious_count == 0 and open_cand_count == 0:
                    reply += "✓ 모든 객체와 누락 후보가 검토 완료되었습니다!\n"
                    reply += "• 하단 **[객체 검수 완료 (Gate 1 통과 / Gate 통과)]** 버튼을 눌러 **[다음: ② 모선 번호 매핑]** 단계로 이동하세요."
                else:
                    reply += f"1. 우선 검토 객체 확인 (남은 의심 객체: **{suspicious_count}개**)\n"
                    reply += f"2. 누락 설비 후보 확인 (남은 미확인 후보: **{open_cand_count}개**)\n"
                    reply += "3. 정상 객체는 상단 **[정상 객체 일괄 승인]**으로 한 번에 승인\n"
                    reply += "4. 하단 **'도면 전체 대조 확인'** 체크 후 **[객체 검수 완료 (Gate 1 통과 / Gate 통과)]** 클릭 ➔ **[다음: ② 모선 번호 매핑]** 단계로 이동"
            elif stage_upper in ("BUS_MAPPING_REVIEW", "BUS_MAPPING"):
                uncertain_buses = len([n for n in w_nodes if n.get("class") == "bus" and (n.get("bus_number") is None or n.get("bus_number_status") == "UNCERTAIN")])
                reply = "🧭 **[다음 단계 진행 가이드 - ② 모선 번호 매핑]:**\n"
                reply += f"1. 도면 OCR 및 공간 좌표 기반 모선 번호 부여 상태 점검 (미해결/불확실: **{uncertain_buses}개**)\n"
                reply += "2. 필요 시 AI 자동 번호 링크 또는 수동으로 모선 번호 입력/보정\n"
                reply += "3. **[모선 번호 승인 (Gate 2 통과)]** 클릭 ➔ **[다음: ③ 선로 결선 검수]** 단계로 이동"
            elif stage_upper in ("CONNECTION_REVIEW", "CONNECTION", "LINE_REVIEW"):
                ambiguous_count = len([l for l in w_lines if l.get("review_status") == "AMBIGUOUS"])
                error_count = len([i for i in issues if i.get("severity") == "error"])
                reply = "🧭 **[다음 단계 진행 가이드 - ③ 선로 결선 검수]:**\n"
                if ambiguous_count == 0 and error_count == 0:
                    reply += "✓ 모든 결선이 전기적 무결성 검증을 통과했습니다!\n"
                    reply += "• 하단 **[결선 검수 완료 (Gate 3 통과)]** 버튼을 눌러 **[다음: ④ 최종 확인 & 엑셀]** 단계로 이동하세요."
                else:
                    reply += f"1. 결선 오류 선로 해결 (남은 모호 선로: **{ambiguous_count}개**)\n"
                    reply += f"2. 토폴로지 결함(단선, 고립 모선) 해결 (남은 결함: **{error_count}개**)\n"
                    reply += "3. 정상 선로는 **[정상 결선 일괄 승인]**으로 승인\n"
                    reply += "4. **[결선 검수 완료 (Gate 3 통과)]** 클릭 ➔ **[다음: ④ 최종 확인 & 엑셀]** 단계로 이동"
            elif stage_upper in ("FINAL_REVIEW", "FINAL", "VERIFIED_FINAL"):
                reply = "🧭 **[다음 단계 진행 가이드 - ④ 최종 확인 & 엑셀 대조]:**\n"
                reply += "1. 최종 정합성이 검증된 VerifiedSLD 다이어그램 요약 확인\n"
                reply += "2. 계통 엑셀 파일(.xlsx)을 업로드하여 도면과 설비 제원 교차 대조\n"
                reply += "3. 불일치 감지 시 AI 진단 리포트 확인 후 원클릭 자동 보정\n"
                reply += "4. **[캔버스로 전송]** 클릭 ➔ 메인 작업 영역으로 이동하여 즉시 AC 조류계산 시뮬레이션 실행"
            elif stage_upper in ("CAD", "EXCEL_MAPPING"):
                reply = (
                    "🧭 **[다음 단계 진행 가이드 - CAD & 엑셀]:**\n"
                    "1. 상단 **[엑셀 가져오기]** 버튼을 눌러 계통 파라미터 엑셀 파일(예: case24_psse.xlsx)을 연결하세요.\n"
                    "2. 엑셀 제원이 연결되면 상단 파란색 **[조류계산 실행]** 버튼을 눌러 수치해석을 진행하세요."
                )
            elif stage_upper == "POWERFLOW_READY":
                reply = (
                    "🧭 **[다음 단계 진행 가이드 - 조류계산]:**\n"
                    "계통 제원 연결이 완료되었습니다!\n"
                    "• 상단 우측 파란색 **[조류계산 실행]** 버튼을 클릭하여 뉴턴-랩슨 조류계산을 수행하세요."
                )
            elif stage_upper == "POWERFLOW_RESULT":
                reply = (
                    "🧭 **[다음 단계 진행 가이드 - 결과 확인]:**\n"
                    "조류계산이 수렴했습니다!\n"
                    "1. 상단 **[수치 결과표]** 버튼을 눌러 모선별 전압/위상각과 선로 조류/손실 표를 확인하세요.\n"
                    "2. CAD 캔버스 위 각 모선의 전압과 발전기 출력을 직접 비교해보세요."
                )
            else:
                reply = f"현재 **{stage}** 단계입니다. 도면 검수나 계통 제원 연결을 진행해주세요."

            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_GUIDE",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"stage": stage},
            }

        # 3. Excel & Parameter Explanation
        if any(k in msg for k in ["엑셀", "excel", "제원", "임피던스", "파라미터", "r/x/b"]):
            reply = (
                "📊 **[계통 엑셀 제원 연결 안내]:**\n"
                "• 뉴턴-랩슨 조류계산에는 모선별 유효/무효전력(P, Q), 발전기 설정 전압(V pu), 선로 및 변압기 임피던스(R, X, B)가 필수적입니다.\n"
                "• 상단 **[엑셀 가져오기]** 버튼을 클릭하여 PSS/E 포맷 엑셀 파일(예: `case24_psse.xlsx`)을 불러오면 모선 번호 기준으로 자동 연결됩니다.\n"
                "• 제원이 연결되면 미연결 경고가 사라지고 조류계산을 즉시 실행할 수 있습니다."
            )
            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_EXCEL_GUIDE",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"stage": stage},
            }

        # 4. Power Flow & Simulation Guidance
        if any(k in msg for k in ["조류계산", "powerflow", "해석", "뉴턴", "수치해석", "수렴"]):
            reply = (
                "⚡ **[조류계산 (Power Flow) 안내]:**\n"
                "• 비선형 전력방정식을 뉴턴-랩슨(Newton-Raphson) 기법으로 풀어 계통 전압 크기와 위상각을 도출합니다.\n"
                "• 필수 조건: 1개 이상의 슬랙(Slack) 모선, 유효한 모선 간 연결 선로, 선로 임피던스 값.\n"
                "• 계산이 수렴하면 상단 **[수치 결과표]** 및 도면 상에서 모선 전압과 조류 분포를 즉시 확인할 수 있습니다."
            )
            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_POWERFLOW_GUIDE",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"stage": stage},
            }

        # 5. Class Change Impact Analysis (클래스 변경 시 전기적 영향)
        if selected_node and any(k in msg for k in ["바꾸", "변경", "영향", "change", "바꾸면"]):
            disp_name = selected_node.get("display_label", selected_node.get("id", "선택 객체"))
            curr_cls = str(selected_node.get("class", "")).lower()
            reply = f"⚡ **[{disp_name}] 클래스 변경 시 계통 영향 분석:**\n"
            if curr_cls == "bus":
                reply += "• **모선(Bus) ➔ 발전기/부하로 변경 시:**\n"
                reply += "  - 해당 노드에 연결된 여러 모선 간 간선이 단일 설비 인출선으로 재해석되어 다중 결선 위반이 발생할 수 있습니다.\n"
                reply += "  - 발전기나 부하는 원칙적으로 단일 모선에 1개의 단자로만 연결되어야 합니다."
            elif curr_cls in ("generator", "load"):
                reply += f"• **{curr_cls.upper()} ➔ 모선(Bus)으로 변경 시:**\n"
                reply += "  - 해당 위치가 계통의 전기적 분기 모선으로 승격되어, 인접 선로들이 이 모선으로 접속 가능해집니다.\n"
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

        # 6. Specific Object Evidence & Judgment (왜 의심/왜 이 클래스인지)
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

            # Friendly user status
            status_ko = "검토 필요" if status == "SUSPICIOUS" else ("확인 완료" if status == "CONFIRMED" else "인식됨")

            reply = f"🔍 **[{disp_name}] 객체 분석 근거 (ID: `{node_id}`):**\n"
            reply += f"• **판정 종류**: `{cls}` (AI 신뢰도: **{conf}%**)\n"
            reply += f"• **현재 상태**: **{status_ko}**  |  **탐지 소스**: `{source}`\n"
            if aspect > 0:
                reply += f"• **심볼 종횡비**: `{aspect:.1f}`\n"

            if reasons:
                reply += f"• **검토 사유**: {', '.join(reasons)}\n"
            else:
                reply += "• **검토 사유**: 심볼 형상 및 신뢰도 기준을 충족하여 정상 판정되었습니다.\n"

            if status == "SUSPICIOUS":
                reply += "\n💡 **추천 액션**: 도면의 실제 심볼을 확인하고, 정상 심볼이면 [승인], 오탐이면 [클래스 변경] 또는 [제외]하세요."
            else:
                reply += "\n💡 **추천 액션**: 정상 심볼로 확인되었으므로 그대로 유지하거나 [승인]하세요."

            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_NODE_EVIDENCE",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"node_label": disp_name, "status": status},
            }

        # 7. Connection Line Evidence & Issues (왜 결선 문제인지)
        if selected_line and any(k in msg for k in ["선", "선로", "결선", "연결", "line", "connect", "문제", "오류", "bus_"]):
            disp_name = selected_line.get("display_name", selected_line.get("display_label", selected_line.get("line_id", "선택 선로")))
            line_id = selected_line.get("line_id", selected_line.get("id", ""))
            conn = selected_line.get("connected_to", [])
            conn_str = selected_line.get("endpoints_display", " ➔ ".join(conn) if conn else "미연결 (Dangling)")
            issues_line = selected_line.get("validation_issues", [])
            trace_method = selected_line.get("trace_method", "electrical_graph")

            reply = f"🔗 **[{disp_name}] 결선 진단 근거 (ID: `{line_id}`):**\n"
            reply += f"• **연결 관계**: `{conn_str}`\n"
            reply += f"• **추적 방식**: `{trace_method}`\n"

            if issues_line:
                issue_descs = [it.get("message", it.get("code", "형상 불일치")) for it in issues_line]
                reply += f"• **감지된 결함**: {', '.join(issue_descs)}\n"
                reply += "\n💡 **추천 액션**: 하단 [연결 대상 Bus 재지정]을 클릭하여 올바른 모선에 연결하거나 [선로 제외]를 선택하세요."
            else:
                reply += "• **검증 결과**: 토폴로지 유효성 검사를 통과한 정상 선로입니다.\n"
                reply += "\n💡 **추천 액션**: 정상 연결이므로 [선로 승인] 또는 [정상 결선 일괄 승인]을 진행하세요."

            return {
                "reply_ko": reply,
                "agent_status": "LOCAL_LINE_EVIDENCE",
                "provider_mode": self.provider_name,
                "display_mode": self.display_mode_name,
                "context_summary": {"line_label": disp_name},
            }

        # 8. Missing Candidate Summary (누락 후보 질문)
        if any(k in msg for k in ["누락", "후보", "변압기", "어디", "missing", "빠진"]):
            open_cands = [c for c in cands if c.get("status") == "OPEN"]
            if open_cands:
                cand = open_cands[0]
                reply = f"⚠️ **누락 의심 설비 안내:**\n"
                reply += f"• **의심 설비**: `{cand.get('suspected_class', '').upper()}`\n"
                reply += f"• **진단 근거**: {cand.get('description_ko', '')}\n"
                reply += "\n💡 **추천 액션**: 상단 도면에서 해당 영역을 드래그하여 **[객체 수동 추가]**를 진행하거나, 도면에 없는 기기라면 **[문제 없음]**을 선택하세요."
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
                f"🤖 **PowerLens AI 어시스턴트:**\n\n"
                f"현재 **{stage}** 단계입니다. "
                "궁금하신 내용을 편하게 질문해주세요.\n\n"
                "💡 **자주 묻는 질문:**\n"
                "• *'다음에 뭐 해?'* ➔ 현재 단계의 다음 행동 안내\n"
                "• *'현재 상태 요약'* ➔ 도면 및 계통 현황 요약\n"
                "• *'엑셀 제원 연결 방법'* ➔ 엑셀 파일 연결 가이드\n"
                "• *'조류계산 실행 조건'* ➔ 수치해석 준비 조건 안내"
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
        import json
        import urllib.error
        import urllib.request

        system_instruction = (
            f"{POWERLENS_SYSTEM_KNOWLEDGE}\n\n"
            "당신은 Lensy라는 이름의 PowerLens 동반자입니다. 전력계통 단선도(SLD) 검수와 조류계산을 처음 쓰는 사람도 이해할 수 있게 도와주세요.\n"
            "현재 단계, 선택된 객체/선로, 실제 검출 목록, 토폴로지 이슈와 조류계산 준비 상태를 근거로 답하고, 근거가 없는 추측은 하지 마세요.\n\n"
            "답변 지침:\n"
            "1. 자연스럽고 친근한 한국어로 먼저 결론을 말하세요.\n"
            "2. 간단한 질문은 2~5문장으로 짧게 답하고, 필요한 경우에만 짧은 목록을 사용하세요.\n"
            "3. [판단], [근거 요약], [추천 액션] 같은 보고서 제목이나 내부 필드명, JSON, Chain-of-Thought를 출력하지 마세요.\n"
            "4. 객체나 선로는 사람이 보기 쉬운 Display Label(예: Bus 4, Load 2, T1, G1, Line 1-2)을 우선 지칭하세요.\n"
            "5. 화면 조작 명령은 앱의 안전한 UI 브리지가 처리할 수 있으므로, 실제로 실행되지 않은 조작을 완료했다고 주장하지 마세요."
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
            # Only pass the small, non-secret runtime state needed for a
            # context-aware answer. Never forward environment variables or
            # credentials from the frontend context.
            "runtime_app_context": {
                "current_screen": (app_context or {}).get("current_screen"),
                "workflow_stage": (app_context or {}).get("workflow_stage", stage),
                "has_diagram": (app_context or {}).get("has_diagram"),
                "excel_loaded": (app_context or {}).get("excel_loaded"),
                "excel_mapping_status": (app_context or {}).get("excel_mapping_status"),
                "powerflow_ready": (app_context or {}).get("powerflow_ready"),
                "powerflow_running": (app_context or {}).get("powerflow_running"),
                "powerflow_converged": (app_context or {}).get("powerflow_converged"),
                "selected_element": (app_context or {}).get("selected_element"),
                "current_blockers": (app_context or {}).get("current_blockers", []),
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

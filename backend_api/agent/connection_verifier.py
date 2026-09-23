"""VisionFlow Agent Connection Verifier with OpenAI Tool Calling and Fallback Explainer."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any, Dict, List, Mapping, Optional, Sequence
import numpy as np

from .connection_evidence import ConnectionEvidence
from .connection_tools import find_candidate_target_buses, inspect_node_ports, validate_topology_graph


@dataclass
class AgentConnectionReviewResult:
    line_id: str
    assessment: str  # CONFIRM, NEEDS_HUMAN_REVIEW, REJECT_CANDIDATE
    message_ko: str
    recommended_action: str  # CONFIRM, ASK_USER, RECONNECT, REJECT
    candidate_targets: List[str] = field(default_factory=list)
    agent_status: str = "AVAILABLE"  # OPENAI_LLM, DETERMINISTIC, ERROR
    retries_used: int = 0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "line_id": self.line_id,
            "assessment": self.assessment,
            "message_ko": self.message_ko,
            "recommended_action": self.recommended_action,
            "candidate_targets": self.candidate_targets,
            "agent_status": self.agent_status,
            "retries_used": self.retries_used,
        }


class AgentConnectionVerifier:
    MAX_CONNECTION_RETRIES: int = 2

    def __init__(self):
        self._api_key = os.environ.get("OPENAI_API_KEY", "").strip()

    @property
    def is_llm_available(self) -> bool:
        return bool(self._api_key)

    def review_connection(
        self,
        evidence: ConnectionEvidence,
        all_nodes: Sequence[Mapping[str, Any]],
        all_lines: Sequence[Mapping[str, Any]],
        image: Optional[np.ndarray] = None,
    ) -> AgentConnectionReviewResult:
        """Review an SLD connection using LLM if available, falling back to deterministic explanation."""
        if not self.is_llm_available:
            return self._deterministic_fallback_review(evidence, all_nodes, all_lines)

        try:
            return self._call_openai_verifier(evidence, all_nodes, all_lines, image)
        except Exception as e:
            fallback = self._deterministic_fallback_review(evidence, all_nodes, all_lines)
            fallback.agent_status = f"ERROR: {str(e)[:80]}"
            return fallback

    def _deterministic_fallback_review(
        self,
        evidence: ConnectionEvidence,
        all_nodes: Sequence[Mapping[str, Any]],
        all_lines: Sequence[Mapping[str, Any]],
    ) -> AgentConnectionReviewResult:
        """Generate high-quality Korean explanations using deterministic topology validation issues."""
        line_id = evidence.line_id
        endpoints = evidence.connected_to
        issues = evidence.validation_issues

        first = endpoints[0] if len(endpoints) > 0 else "?"
        second = endpoints[1] if len(endpoints) > 1 else "?"

        candidate_buses = [
            b["bus_id"]
            for b in find_candidate_target_buses(first, all_nodes, all_lines)
        ]

        if not issues and not evidence.is_ambiguous:
            return AgentConnectionReviewResult(
                line_id=line_id,
                assessment="CONFIRM",
                message_ko=f"선로 {line_id}는 {first}와 {second} 간의 정상적인 전기적 결선으로 확인되었습니다.",
                recommended_action="CONFIRM",
                candidate_targets=[],
                agent_status="DETERMINISTIC",
                retries_used=0,
            )

        # Build specific message based on first major issue
        primary_issue = issues[0] if issues else {}
        code = primary_issue.get("code", "")

        if code == "invalid_terminal_degree":
            comp = primary_issue.get("component_ids", (first,))[0]
            message_ko = (
                f"발전기/부하 기기 '{comp}'는 정확히 1개의 Bus에 연결되어야 하지만 단자 연결 수가 비정상입니다. "
                "결선 위치를 확인하거나 재연결해 주세요."
            )
            recommended_action = "ASK_USER"
        elif code == "invalid_device_pair":
            message_ko = (
                f"부하(Load) 또는 발전기(Generator) '{first}'와 '{second}'가 직접 연결되어 있습니다. "
                "기기는 반드시 모선(Bus)을 거쳐 연결되어야 하므로 결선 수정이 필요합니다."
            )
            recommended_action = "RECONNECT"
        elif code == "self_loop":
            message_ko = f"선로 {line_id}가 동일한 컴포넌트 '{first}'에 루프로 연결되어 있습니다. 삭제를 권장합니다."
            recommended_action = "REJECT"
        elif code == "unknown_endpoint":
            message_ko = f"선로 {line_id}의 끝점이 알 수 없는 객체를 참조하고 있습니다. 재연결 또는 삭제해 주세요."
            recommended_action = "ASK_USER"
        elif code == "duplicate_edge":
            message_ko = f"'{first}'와 '{second}' 사이에 중복된 선로({line_id})가 존재합니다."
            recommended_action = "REJECT"
        elif code == "dangling_connection":
            message_ko = f"선로 {line_id}의 끝점이 한 쪽에만 연결되어 있습니다. 연결할 대상 Bus를 지정해 주세요."
            recommended_action = "RECONNECT"
        elif code == "invalid_transformer_degree":
            comp = primary_issue.get("component_ids", (first,))[0]
            message_ko = f"변압기 '{comp}'의 노출 포트 수가 1개 또는 2개가 아닙니다. 단선도 연결 관계를 확인해 주세요."
            recommended_action = "ASK_USER"
        else:
            message_ko = f"선로 {line_id} ({first} ➔ {second})의 연결 구조에 전기적 검토가 필요합니다."
            recommended_action = "ASK_USER"

        return AgentConnectionReviewResult(
            line_id=line_id,
            assessment="NEEDS_HUMAN_REVIEW",
            message_ko=message_ko,
            recommended_action=recommended_action,
            candidate_targets=candidate_buses[:3],
            agent_status="DETERMINISTIC",
            retries_used=0,
        )

    def _call_openai_verifier(
        self,
        evidence: ConnectionEvidence,
        all_nodes: Sequence[Mapping[str, Any]],
        all_lines: Sequence[Mapping[str, Any]],
        image: Optional[np.ndarray] = None,
    ) -> AgentConnectionReviewResult:
        """Call OpenAI Responses API to verify connection with domain prompt."""
        import openai

        client = openai.OpenAI(api_key=self._api_key)

        candidate_buses = [
            b["bus_id"]
            for b in find_candidate_target_buses(
                evidence.connected_to[0] if evidence.connected_to else "",
                all_nodes,
                all_lines,
            )
        ]

        prompt = (
            f"You are the VisionFlow Electrical Topology Verifier Agent.\n"
            f"Line Evidence for review:\n"
            f"- Line ID: {evidence.line_id}\n"
            f"- Connected To: {evidence.connected_to}\n"
            f"- Source Port: {evidence.source_port}, Target Port: {evidence.target_port}\n"
            f"- Path Length: {evidence.geometry.get('path_length', 0)} px\n"
            f"- Validation Issues: {json.dumps(evidence.validation_issues, ensure_ascii=False)}\n"
            f"- Candidate Nearby Buses: {candidate_buses}\n\n"
            f"Instructions:\n"
            f"1. Explain clearly in natural Korean (한국어) what is wrong or confirmed with this connection.\n"
            f"2. Keep the message concise (1-2 sentences) and actionable.\n"
            f"3. Return a strict JSON response with keys: 'assessment' ('CONFIRM' | 'NEEDS_HUMAN_REVIEW' | 'REJECT_CANDIDATE'), "
            f"'message_ko', 'recommended_action' ('CONFIRM' | 'ASK_USER' | 'RECONNECT' | 'REJECT'), "
            f"'candidate_targets' (list of bus IDs)."
        )

        response = client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": "You are a professional Power Systems Single Line Diagram (SLD) connection verifier."},
                {"role": "user", "content": prompt},
            ],
            response_format={"type": "json_object"},
            temperature=0.2,
            max_tokens=300,
        )

        content = response.choices[0].message.content or "{}"
        parsed = json.loads(content)

        return AgentConnectionReviewResult(
            line_id=evidence.line_id,
            assessment=str(parsed.get("assessment", "NEEDS_HUMAN_REVIEW")),
            message_ko=str(parsed.get("message_ko", "결선 확인이 필요합니다.")),
            recommended_action=str(parsed.get("recommended_action", "ASK_USER")),
            candidate_targets=list(parsed.get("candidate_targets", candidate_buses[:3])),
            agent_status="OPENAI_LLM",
            retries_used=1,
        )


# Global singleton connection verifier
connection_verifier = AgentConnectionVerifier()

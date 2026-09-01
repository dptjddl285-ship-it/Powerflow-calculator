"""VisionFlow Agent Object Reviewer with OpenAI Tool Calling and Fallback Explainer."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional
import numpy as np

from .evidence_extractor import ObjectEvidence
from .tools import (
    reanalyze_bus_roi,
    reanalyze_generator_roi,
    reanalyze_load_roi,
    reanalyze_transformer_roi,
)


@dataclass
class AgentReviewResult:
    node_id: str
    assessment: str  # CONFIRM, NEEDS_HUMAN_REVIEW, REJECT_CANDIDATE, SUGGEST_CLASS_CHANGE
    message_ko: str
    recommended_action: str  # CONFIRM, ASK_USER, CHANGE_CLASS, REJECT
    suggested_classes: List[str] = field(default_factory=list)
    agent_status: str = "AVAILABLE"  # AVAILABLE, UNAVAILABLE, ERROR
    retries_used: int = 0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "node_id": self.node_id,
            "assessment": self.assessment,
            "message_ko": self.message_ko,
            "recommended_action": self.recommended_action,
            "suggested_classes": self.suggested_classes,
            "agent_status": self.agent_status,
            "retries_used": self.retries_used,
        }


class AgentObjectReviewer:
    MAX_RETRIES: int = 2

    def __init__(self):
        self._api_key = os.environ.get("OPENAI_API_KEY", "").strip()

    @property
    def is_llm_available(self) -> bool:
        return bool(self._api_key)

    def review_object(
        self,
        evidence: ObjectEvidence,
        image: Optional[np.ndarray] = None,
    ) -> AgentReviewResult:
        """Review an SLD object using LLM if available, falling back to deterministic explanation."""
        if not self.is_llm_available:
            return self._deterministic_fallback_review(evidence, image)

        try:
            return self._call_openai_reviewer(evidence, image)
        except Exception as e:
            # Fallback gracefully if OpenAI call fails
            fallback = self._deterministic_fallback_review(evidence, image)
            fallback.agent_status = f"ERROR: {str(e)[:80]}"
            return fallback

    def _deterministic_fallback_review(
        self,
        evidence: ObjectEvidence,
        image: Optional[np.ndarray] = None,
    ) -> AgentReviewResult:
        """Generate high-quality Korean explanations using deterministic domain heuristics."""
        node_id = evidence.node_id
        class_name = evidence.class_name.lower()
        conf = evidence.confidence
        reasons = evidence.suspicious_reasons

        # Default fallback structure
        assessment = "NEEDS_HUMAN_REVIEW" if evidence.is_suspicious else "CONFIRM"
        recommended_action = "ASK_USER" if evidence.is_suspicious else "CONFIRM"
        suggested_classes = [class_name]

        # Class-specific explanation generation
        if not evidence.is_suspicious:
            message_ko = f"정상적인 {class_name.upper()} 심볼로 판정되었습니다. (신뢰도: {conf*100:.1f}%)"
            return AgentReviewResult(
                node_id=node_id,
                assessment="CONFIRM",
                message_ko=message_ko,
                recommended_action="CONFIRM",
                suggested_classes=[class_name],
                agent_status="DETERMINISTIC",
                retries_used=0,
            )

        # Build Korean explanation based on reasons
        if "다른 객체" in str(reasons) or "중첩" in str(reasons):
            message_ko = f"{class_name.upper()} 후보가 인접한 다른 심볼과 영역이 겹쳐 있습니다. 오검출 여부나 정확한 영역을 확인해 주세요."
            suggested_classes = ["bus", "generator", "load", "transformer"]
        elif class_name == "load":
            if image is not None:
                roi_res = reanalyze_load_roi(image, evidence.bbox)
                if roi_res.get("is_arrowhead"):
                    message_ko = f"신뢰도는 다소 낮으나({conf*100:.1f}%) ROI 형상 재분석에서 부하(Load) 화살표 형태가 확인되었습니다."
                    suggested_classes = ["load"]
                else:
                    message_ko = f"Load로 검출되었으나 신뢰도가 낮고({conf*100:.1f}%) 화살표 윤곽 근거가 부족합니다. 원본 도면을 확인해 주세요."
                    suggested_classes = ["load", "generator"]
            else:
                message_ko = f"Load로 검출되었으나 신뢰도({conf*100:.1f}%)가 낮고 단자 추적이 불안정합니다. 원본을 확인해 주세요."
                suggested_classes = ["load", "generator"]
        elif class_name == "generator":
            if image is not None:
                roi_res = reanalyze_generator_roi(image, evidence.bbox)
                if roi_res.get("has_circle"):
                    message_ko = f"Generator 원형 심볼 구조가 확인되었으나 신뢰도({conf*100:.1f}%) 보강이 필요합니다."
                    suggested_classes = ["generator", "transformer"]
                else:
                    message_ko = f"Generator로 제안되었으나 원형 회로 기호 근거가 약합니다. 변압기(Transformer) 또는 노이즈 여부를 확인해 주세요."
                    suggested_classes = ["generator", "transformer", "load"]
            else:
                message_ko = f"Generator 후보이지만 원형 도면 구조 근거가 약합니다. 변압기 또는 오검출 여부를 확인해 주세요."
                suggested_classes = ["generator", "transformer"]
        elif class_name == "transformer":
            if image is not None:
                roi_res = reanalyze_transformer_roi(image, evidence.bbox)
                if roi_res.get("is_pair"):
                    message_ko = f"Transformer 2권선 심볼 구조가 확인되었습니다. (신뢰도: {conf*100:.1f}%)"
                    suggested_classes = ["transformer"]
                else:
                    message_ko = f"Transformer 후보이지만 두 권선 구조의 독립 포트가 명확하지 않습니다. Generator 또는 원본을 확인해 주세요."
                    suggested_classes = ["transformer", "generator"]
            else:
                message_ko = f"Transformer 후보이지만 두 권선 구조가 명확하지 않습니다. 원본을 확인해 주세요."
                suggested_classes = ["transformer", "generator"]
        elif class_name == "bus":
            message_ko = f"Bus로 인식되었으나 길이와 두께 비율이 일반적인 Bus 패턴과 다릅니다. 실제 모선인지 확인해 주세요."
            suggested_classes = ["bus"]
        else:
            message_ko = f"AI 신뢰도({conf*100:.1f}%)가 기준치 미만입니다. 원본 도면을 검토해 주세요."
            suggested_classes = ["bus", "generator", "load", "transformer"]

        return AgentReviewResult(
            node_id=node_id,
            assessment=assessment,
            message_ko=message_ko,
            recommended_action=recommended_action,
            suggested_classes=suggested_classes,
            agent_status="DETERMINISTIC",
            retries_used=0,
        )

    def _call_openai_reviewer(
        self,
        evidence: ObjectEvidence,
        image: Optional[np.ndarray] = None,
    ) -> AgentReviewResult:
        """Call OpenAI Responses / Tool Calling API to review object."""
        # Using official openai sdk
        import openai

        client = openai.OpenAI(api_key=self._api_key)

        # Perform ROI analysis tools if image provided
        tools_evidence = {}
        if image is not None:
            if evidence.class_name == "generator":
                tools_evidence["circle_reanalysis"] = reanalyze_generator_roi(image, evidence.bbox)
            elif evidence.class_name == "transformer":
                tools_evidence["transformer_reanalysis"] = reanalyze_transformer_roi(image, evidence.bbox)
            elif evidence.class_name == "load":
                tools_evidence["arrowhead_reanalysis"] = reanalyze_load_roi(image, evidence.bbox)
            elif evidence.class_name == "bus":
                tools_evidence["bus_reanalysis"] = reanalyze_bus_roi(image, evidence.bbox)

        prompt = (
            f"You are the VisionFlow AI Circuit Diagram Expert Agent.\n"
            f"Object Evidence for review:\n"
            f"- Node ID: {evidence.node_id}\n"
            f"- Proposed Class: {evidence.class_name}\n"
            f"- AI Confidence: {evidence.confidence:.3f}\n"
            f"- Detector Source: {evidence.source}\n"
            f"- Suspicious Reasons: {json.dumps(evidence.suspicious_reasons, ensure_ascii=False)}\n"
            f"- Tool Re-analysis Evidence: {json.dumps(tools_evidence, ensure_ascii=False)}\n\n"
            f"Instructions:\n"
            f"1. Explain clearly in natural Korean (한국어) why this object is suspicious or acceptable.\n"
            f"2. Keep the message concise (1-2 sentences) and focused on actionable evidence (do NOT expose internal CoT).\n"
            f"3. Return a strict JSON response with keys: 'assessment' ('CONFIRM' | 'NEEDS_HUMAN_REVIEW' | 'REJECT_CANDIDATE'), "
            f"'message_ko', 'recommended_action' ('CONFIRM' | 'ASK_USER' | 'CHANGE_CLASS' | 'REJECT'), "
            f"'suggested_classes' (list of classes)."
        )

        response = client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": "You are a professional Power Systems Single Line Diagram (SLD) verification agent."},
                {"role": "user", "content": prompt},
            ],
            response_format={"type": "json_object"},
            temperature=0.2,
            max_tokens=300,
        )

        content = response.choices[0].message.content or "{}"
        parsed = json.loads(content)

        return AgentReviewResult(
            node_id=evidence.node_id,
            assessment=str(parsed.get("assessment", "NEEDS_HUMAN_REVIEW")),
            message_ko=str(parsed.get("message_ko", "도면 검토가 필요합니다.")),
            recommended_action=str(parsed.get("recommended_action", "ASK_USER")),
            suggested_classes=list(parsed.get("suggested_classes", [evidence.class_name])),
            agent_status="OPENAI_LLM",
            retries_used=1,
        )


# Global singleton reviewer
object_reviewer = AgentObjectReviewer()

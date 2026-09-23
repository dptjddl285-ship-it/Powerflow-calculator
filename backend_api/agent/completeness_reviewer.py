"""Global Diagram Completeness Reviewer for VisionFlow.

Analyzes the overall diagram and working object set to surface missing-candidate
hypotheses (e.g. transformers or loads that the primary YOLO/CV models completely missed)
before passing the Object Gate.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import json
import os
from typing import Any, Dict, List, Mapping, Optional, Sequence


@dataclass
class MissingCandidate:
    id: str
    suspected_class: str
    description_ko: str
    approximate_region: Optional[List[float]] = None  # [cx, cy, w, h] hint only (NOT final bbox)
    status: str = "OPEN"  # OPEN, RESOLVED_BY_MANUAL_ADD, DISMISSED_BY_HUMAN
    source: str = "agent_completeness"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "suspected_class": self.suspected_class,
            "description_ko": self.description_ko,
            "approximate_region": self.approximate_region,
            "status": self.status,
            "source": self.source,
        }


@dataclass
class CompletenessReviewResult:
    assessment: str  # ALL_EXPECTED_PRESENT, POSSIBLE_MISSING_COMPONENT, NEEDS_HUMAN_INSPECTION
    message_ko: str
    candidates: List[MissingCandidate] = field(default_factory=list)
    class_counts: Dict[str, int] = field(default_factory=dict)
    agent_status: str = "DETERMINISTIC"  # OPENAI or DETERMINISTIC

    def to_dict(self) -> Dict[str, Any]:
        return {
            "assessment": self.assessment,
            "message_ko": self.message_ko,
            "candidates": [c.to_dict() for c in self.candidates],
            "class_counts": self.class_counts,
            "agent_status": self.agent_status,
        }


class AgentCompletenessReviewer:
    """Agent for global single line diagram completeness review."""

    def __init__(self, model_name: str = "gpt-4o"):
        self.model_name = model_name
        self.api_key = os.getenv("OPENAI_API_KEY")

    def review_completeness(
        self,
        working_nodes: Sequence[Mapping[str, Any]],
        image: Optional[Any] = None,
        image_bytes: Optional[bytes] = None,
        lines: Optional[Sequence[Mapping[str, Any]]] = None,
    ) -> CompletenessReviewResult:
        """Inspects whole diagram and working nodes for possible missing components."""
        class_counts: Dict[str, int] = {}
        for n in working_nodes:
            cls = str(n.get("class", "unknown")).lower()
            class_counts[cls] = class_counts.get(cls, 0) + 1

        # Attempt OpenAI if key is present
        if self.api_key:
            try:
                return self._openai_review(working_nodes, class_counts, image=image, image_bytes=image_bytes)
            except Exception as e:
                print(f"[AgentCompletenessReviewer] OpenAI call failed: {e}. Falling back to deterministic review.")

        return self._deterministic_fallback_review(working_nodes, class_counts, image=image, lines=lines)

    def _openai_review(
        self,
        working_nodes: Sequence[Mapping[str, Any]],
        class_counts: Dict[str, int],
        image: Optional[Any] = None,
        image_bytes: Optional[bytes] = None,
    ) -> CompletenessReviewResult:
        import openai

        client = openai.OpenAI(api_key=self.api_key)

        prompt = (
            "You are an expert Electrical Single Line Diagram (SLD) Completeness Verifier.\n"
            f"Currently detected components in diagram: {json.dumps(class_counts)}\n"
            f"Detected nodes summary: {len(working_nodes)} objects.\n"
            "Compare the whole electrical diagram image with the detected components.\n"
            "Identify if there are any major electrical components (such as Transformers, Generators, Loads, or Buses) "
            "clearly visible in the diagram that were completely missed by the object detector.\n"
            "Return JSON with format:\n"
            "{\n"
            "  \"assessment\": \"POSSIBLE_MISSING_COMPONENT\" or \"ALL_EXPECTED_PRESENT\",\n"
            "  \"message_ko\": \"Korean explanation for human engineer\",\n"
            "  \"candidates\": [\n"
            "    {\n"
            "      \"suspected_class\": \"transformer\" | \"load\" | \"generator\" | \"bus\",\n"
            "      \"description_ko\": \"Korean description of where it is located\",\n"
            "      \"approximate_region\": [cx, cy, w, h] or null\n"
            "    }\n"
            "  ]\n"
            "}"
        )

        response = client.chat.completions.create(
            model=self.model_name,
            messages=[
                {"role": "system", "content": "You are a professional power grid diagram verification agent."},
                {"role": "user", "content": prompt},
            ],
            response_format={"type": "json_object"},
            temperature=0.1,
        )

        content = response.choices[0].message.content or "{}"
        data = json.loads(content)

        candidates = []
        for i, c in enumerate(data.get("candidates", [])):
            candidates.append(
                MissingCandidate(
                    id=f"missing_cand_{i+1}",
                    suspected_class=c.get("suspected_class", "transformer"),
                    description_ko=c.get("description_ko", "미검출 설비 후보"),
                    approximate_region=c.get("approximate_region"),
                    status="OPEN",
                )
            )

        return CompletenessReviewResult(
            assessment=data.get("assessment", "POSSIBLE_MISSING_COMPONENT" if candidates else "ALL_EXPECTED_PRESENT"),
            message_ko=data.get("message_ko", "전체 도면 검수 완료"),
            candidates=candidates,
            class_counts=class_counts,
            agent_status="OPENAI",
        )

    def _deterministic_fallback_review(
        self,
        working_nodes: Sequence[Mapping[str, Any]],
        class_counts: Dict[str, int],
        image: Optional[Any] = None,
        lines: Optional[Sequence[Mapping[str, Any]]] = None,
    ) -> CompletenessReviewResult:
        """Deterministic rule-based heuristics for diagram completeness."""
        bus_count = class_counts.get("bus", 0)
        transformer_count = class_counts.get("transformer", 0)
        gen_count = class_counts.get("generator", 0)
        load_count = class_counts.get("load", 0)

        candidates: List[MissingCandidate] = []

        # Heuristic 1: Multiple buses present but 0 transformers in a multi-bus system
        if bus_count >= 3 and transformer_count == 0:
            candidates.append(
                MissingCandidate(
                    id="cand_trans_missing_1",
                    suspected_class="transformer",
                    description_ko=f"모선(Bus)이 {bus_count}개 검출되었으나 변압기(Transformer)가 0개입니다. 모선 간 연계 변압기 권선 심볼이 누락되었는지 확인해 주세요.",
                    approximate_region=None,
                    status="OPEN",
                )
            )

        # Heuristic 2: Loads or Generators completely missing in a grid with many buses
        if bus_count >= 4 and load_count == 0:
            candidates.append(
                MissingCandidate(
                    id="cand_load_missing_1",
                    suspected_class="load",
                    description_ko=f"모선이 {bus_count}개 검출되었으나 부하(Load) 화살표 심볼이 0개입니다. 부하 기기 누락 여부를 확인해 주세요.",
                    approximate_region=None,
                    status="OPEN",
                )
            )

        if bus_count >= 4 and gen_count == 0:
            candidates.append(
                MissingCandidate(
                    id="cand_gen_missing_1",
                    suspected_class="generator",
                    description_ko=f"모선이 {bus_count}개 검출되었으나 발전기(Generator) 원형 심볼이 0개입니다. 전원 설비 누락 여부를 확인해 주세요.",
                    approximate_region=None,
                    status="OPEN",
                )
            )

        if candidates:
            assessment = "POSSIBLE_MISSING_COMPONENT"
            msg = (
                f"전체 계통 구성 분석 결과 {len(candidates)}건의 설비 누락 가능성이 감지되었습니다. "
                "원본 도면과 비교하여 미검출된 기기가 있다면 [객체 수동 추가]를 진행하거나, 정상인 경우 [문제 없음]을 선택해 주세요."
            )
        else:
            assessment = "NEEDS_HUMAN_INSPECTION"
            msg = (
                "전체 도면 기본 통계 검사 완료. "
                "자동 누락 검사는 제한적이므로 원본 회로도 전체를 직접 육안으로 비교하여 누락된 설비가 없는지 최종 확인해 주세요."
            )

        return CompletenessReviewResult(
            assessment=assessment,
            message_ko=msg,
            candidates=candidates,
            class_counts=class_counts,
            agent_status="DETERMINISTIC",
        )


completeness_reviewer = AgentCompletenessReviewer()

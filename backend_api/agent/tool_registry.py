"""Issue-aware registry for existing Review Tools."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from agent_tools.vision_tools import ReviewVisionToolRunner
from review.graph_document import GraphDocument, ReviewIssue
from review.patches import PatchPreview
from review.store import AnalysisAsset


@dataclass(frozen=True)
class RegisteredReviewTool:
    name: str
    description: str
    issue_codes: frozenset[str]
    executor: Callable[..., PatchPreview]


@dataclass(frozen=True)
class ToolCandidate:
    name: str
    reason: str


class ReviewToolRegistry:
    """Maps Issue evidence to bounded existing-tool candidates."""

    _PORT_FIRST_CODES = frozenset({
        "invalid_terminal_degree",
        "invalid_transformer_degree",
        "missing_transformer_port",
        "disconnected_generator",
        "disconnected_load",
        "unconnected_added_candidate",
    })
    _ROI_FIRST_CODES = frozenset({
        "isolated_bus",
        "user_missing_component_roi",
        "missing_object_candidates",
        "suspicious_added_bus",
        "bus_fragmentation",
        "fragmented_bus",
        "duplicate_component",
        "low_confidence_component",
        "abnormal_geometry",
        "multiple_connection_candidates",
    })

    def __init__(self, runner: ReviewVisionToolRunner) -> None:
        self._runner = runner
        supported = frozenset(self._PORT_FIRST_CODES | self._ROI_FIRST_CODES)
        self._tools = {
            "port_aware_retry": RegisteredReviewTool(
                name="port_aware_retry",
                description="기존 포트 인식과 실제 픽셀 선로 추적을 Issue 주변에서 재실행",
                issue_codes=supported,
                executor=runner.create_preview,
            ),
            "roi_reanalysis": RegisteredReviewTool(
                name="roi_reanalysis",
                description="기존 Vision/CV 파이프라인을 Issue ROI에서 재실행",
                issue_codes=supported,
                executor=runner.create_preview,
            ),
        }

    def get(self, name: str) -> RegisteredReviewTool:
        tool = self._tools.get(name)
        if tool is None:
            raise KeyError(f"unregistered Review Tool: {name}")
        return tool

    def candidates(
        self,
        *,
        document: GraphDocument,
        issue: ReviewIssue,
        object_only: bool,
    ) -> list[ToolCandidate]:
        node_types = {
            node.type
            for node in document.nodes
            if node.internal_id in set(issue.component_ids)
        }
        is_connection_issue = (
            issue.code in self._PORT_FIRST_CODES
            or bool(node_types & {"generator", "load", "transformer"})
        )
        if object_only:
            order = ["roi_reanalysis"]
        elif is_connection_issue:
            order = ["port_aware_retry", "roi_reanalysis"]
        else:
            order = ["roi_reanalysis"]
            if issue.component_ids:
                order.append("port_aware_retry")

        suggested = [
            name for name in issue.suggested_tools
            if name in self._tools and name in order
        ]
        if suggested:
            first = suggested[0]
            order = [first, *(name for name in order if name != first)]

        reasons = {
            "port_aware_retry": (
                "Issue가 객체 포트 또는 결선 차수와 관련되어 기존 포트 기반 선로 재추적을 우선 실행"
            ),
            "roi_reanalysis": (
                "국소 ROI에서 기존 객체 검출과 선로 추적을 함께 재실행하여 대체 후보를 확인"
            ),
        }
        return [ToolCandidate(name=name, reason=reasons[name]) for name in order[:2]]

    def execute(
        self,
        *,
        tool_name: str,
        document: GraphDocument,
        issue: ReviewIssue,
        asset: AnalysisAsset,
    ) -> PatchPreview:
        tool = self.get(tool_name)
        return tool.executor(
            tool_name=tool.name,
            document=document,
            issue=issue,
            asset=asset,
        )


__all__ = ["RegisteredReviewTool", "ReviewToolRegistry", "ToolCandidate"]

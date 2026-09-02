"""Provider boundary for deterministic now and an LLM planner later.

Providers only plan registered tools.  They never execute tools, create pixel
coordinates, or mutate a GraphDocument.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, Sequence

from review.agent_activity import AgentPlanStep
from review.graph_document import GraphDocument, ReviewIssue


@dataclass(frozen=True)
class ReviewPlanningContext:
    issue: ReviewIssue
    graph_summary: dict[str, Any]
    available_tools: tuple[str, ...]
    object_only: bool = False


class ReviewPlanningProvider(ABC):
    """Replaceable plan provider; execution remains deterministic."""

    name = "abstract"

    @abstractmethod
    def build_plan(
        self,
        *,
        document: GraphDocument,
        context: ReviewPlanningContext,
        max_attempts: int,
    ) -> list[AgentPlanStep]:
        raise NotImplementedError


class LocalRulePlanningProvider(ReviewPlanningProvider):
    """API-key-free planner using the Tool Registry's ordered candidates."""

    name = "local_rule_provider"

    def build_plan(
        self,
        *,
        document: GraphDocument,
        context: ReviewPlanningContext,
        max_attempts: int,
    ) -> list[AgentPlanStep]:
        del document
        reasons = context.graph_summary.get("tool_reasons", {})
        return [
            AgentPlanStep(
                attempt=index + 1,
                tool_name=tool_name,
                reason=str(reasons.get(tool_name) or "Issue와 현재 Graph 상태에 적용 가능한 도구"),
            )
            for index, tool_name in enumerate(context.available_tools[:max_attempts])
        ]


__all__ = [
    "LocalRulePlanningProvider",
    "ReviewPlanningContext",
    "ReviewPlanningProvider",
]

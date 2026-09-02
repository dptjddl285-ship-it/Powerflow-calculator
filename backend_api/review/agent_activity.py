"""Persisted, preview-only activity records for Review Agent runs."""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Literal

from pydantic import Field

from .graph_document import StrictModel


class AgentRunStatus(str, Enum):
    AWAITING_APPROVAL = "AWAITING_APPROVAL"
    NO_IMPROVEMENT = "NO_IMPROVEMENT"
    FAILED = "FAILED"


class AgentPlanStep(StrictModel):
    attempt: int = Field(ge=1, le=2)
    tool_name: Literal["roi_reanalysis", "port_aware_retry"]
    reason: str


class AgentToolEvaluation(StrictModel):
    attempt: int = Field(ge=1, le=2)
    tool_name: Literal["roi_reanalysis", "port_aware_retry"]
    patch_id: str
    patch_status: str
    improved: bool
    before_score: int
    after_score: int
    target_issue_before: int
    target_issue_after: int
    operation_count: int = Field(ge=0)
    reason: str
    metrics: dict[str, Any] = Field(default_factory=dict)


class AgentActivityEntry(StrictModel):
    sequence: int = Field(ge=1)
    event: Literal[
        "issue_detected",
        "plan_created",
        "tool_selected",
        "tool_completed",
        "result_evaluated",
        "retry_scheduled",
        "final_decision",
        "patch_registered",
        "run_failed",
    ]
    message: str
    tool_name: str | None = None
    reason: str | None = None
    patch_id: str | None = None
    details: dict[str, Any] = Field(default_factory=dict)
    created_at: datetime


class ReviewAgentRun(StrictModel):
    run_id: str
    document_id: str
    issue_id: str
    base_revision: int = Field(ge=1)
    provider: str
    status: AgentRunStatus
    plan: list[AgentPlanStep] = Field(default_factory=list, max_length=2)
    evaluations: list[AgentToolEvaluation] = Field(default_factory=list, max_length=2)
    activity_log: list[AgentActivityEntry] = Field(default_factory=list)
    selected_patch_id: str | None = None
    created_at: datetime
    completed_at: datetime


__all__ = [
    "AgentActivityEntry",
    "AgentPlanStep",
    "AgentRunStatus",
    "AgentToolEvaluation",
    "ReviewAgentRun",
]

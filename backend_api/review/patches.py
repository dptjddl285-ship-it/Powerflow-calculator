"""Preview-only graph changes produced by Review Tools."""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Literal

from pydantic import Field, model_validator

from .graph_document import GraphEdge, GraphNode, Port, StrictModel


class PatchStatus(str, Enum):
    PENDING = "PENDING"
    NO_CHANGE = "NO_CHANGE"
    APPLIED = "APPLIED"
    REJECTED = "REJECTED"


class RoiBounds(StrictModel):
    x_min: int = Field(ge=0)
    y_min: int = Field(ge=0)
    x_max: int = Field(gt=0)
    y_max: int = Field(gt=0)

    @model_validator(mode="after")
    def bounds_are_ordered(self) -> "RoiBounds":
        if self.x_max <= self.x_min or self.y_max <= self.y_min:
            raise ValueError("ROI bounds must have positive area")
        return self


class PatchOperation(StrictModel):
    operation: Literal["add_node", "add_edge", "remove_edge", "replace_edge"]
    target_id: str | None = None
    node: GraphNode | None = None
    edge: GraphEdge | None = None
    ports: list[Port] = Field(default_factory=list)

    @model_validator(mode="after")
    def payload_matches_operation(self) -> "PatchOperation":
        if self.operation == "add_node" and self.node is None:
            raise ValueError("add_node requires node")
        if self.operation in {"add_edge", "replace_edge"}:
            if self.edge is None or len(self.ports) != 2:
                raise ValueError(f"{self.operation} requires an edge and two ports")
        if self.operation in {"remove_edge", "replace_edge"} and not self.target_id:
            raise ValueError(f"{self.operation} requires target_id")
        return self


class PatchPreview(StrictModel):
    patch_id: str
    document_id: str
    base_revision: int = Field(ge=1)
    issue_id: str
    tool_name: Literal[
        "roi_reanalysis",
        "port_aware_retry",
        "missing_object_scan",
    ]
    status: PatchStatus
    roi: RoiBounds
    summary: str
    evidence: list[str] = Field(default_factory=list)
    operations: list[PatchOperation] = Field(default_factory=list)
    analysis_snapshot: dict[str, Any] = Field(default_factory=dict)
    created_at: datetime
    decided_at: datetime | None = None


__all__ = [
    "PatchOperation",
    "PatchPreview",
    "PatchStatus",
    "RoiBounds",
]

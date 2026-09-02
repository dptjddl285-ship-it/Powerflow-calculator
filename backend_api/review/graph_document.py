"""Versioned data contract shared by Vision, Review, and Flutter.

The existing detector returns compact dictionaries for backwards compatibility.
These models provide the stable contract used by the review workflow without
changing the proven pixel-level detector output.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True)


class GraphStatus(str, Enum):
    DRAFT = "DRAFT"
    IN_REVIEW = "IN_REVIEW"
    VERIFIED = "VERIFIED"


class ReviewState(str, Enum):
    ACCEPTED = "accepted"
    AUTO_RESCUED = "auto_rescued"
    NEEDS_REVIEW = "needs_review"


class IssueStatus(str, Enum):
    OPEN = "open"
    RESOLVED = "resolved"
    ACKNOWLEDGED = "acknowledged"


class PixelPoint(StrictModel):
    x: float
    y: float


class CenterBBox(StrictModel):
    """Original-image pixel bbox: center_x, center_y, width, height."""

    center_x: float
    center_y: float
    width: float = Field(gt=0)
    height: float = Field(gt=0)


class ImageRegion(StrictModel):
    """Axis-aligned region in original-image pixel coordinates."""

    x_min: float = Field(ge=0)
    y_min: float = Field(ge=0)
    x_max: float = Field(gt=0)
    y_max: float = Field(gt=0)

    @model_validator(mode="after")
    def bounds_are_ordered(self) -> "ImageRegion":
        if self.x_max <= self.x_min or self.y_max <= self.y_min:
            raise ValueError("image region must have positive area")
        return self


class ImageMetadata(StrictModel):
    filename: str | None = None
    width: int = Field(ge=0)
    height: int = Field(ge=0)
    coordinate_system: Literal["original_image_pixels_center_xywh"] = (
        "original_image_pixels_center_xywh"
    )


class GraphNode(StrictModel):
    internal_id: str
    source_id: str
    type: Literal["bus", "generator", "load", "transformer"]
    bbox: CenterBBox
    original_bbox: CenterBBox
    confidence: float = Field(ge=0.0, le=1.0)
    source: str
    review_state: ReviewState
    ports: list[str] = Field(default_factory=list)
    display_name: str | None = None
    display_bus_no: int | None = Field(default=None, ge=0)
    parameters: dict[str, Any] = Field(default_factory=dict)


class Port(StrictModel):
    port_id: str
    node_id: str
    side: str
    point: PixelPoint
    score: float | None = None
    distance: float | None = None


class GraphEdge(StrictModel):
    internal_id: str
    source_id: str
    type: Literal["conductor"] = "conductor"
    source_node_id: str
    target_node_id: str
    source_port_id: str
    target_port_id: str
    path: list[PixelPoint] = Field(min_length=2)
    trace_method: str

    @model_validator(mode="after")
    def endpoints_must_differ(self) -> "GraphEdge":
        if self.source_node_id == self.target_node_id:
            raise ValueError("edge endpoints must be different")
        return self


class ReviewIssue(StrictModel):
    issue_id: str
    severity: Literal["error", "warning", "info"]
    code: str
    message: str
    component_ids: list[str] = Field(default_factory=list)
    roi: ImageRegion | None = None
    status: IssueStatus = IssueStatus.OPEN
    suggested_tools: list[str] = Field(default_factory=list)


class RescueRecord(StrictModel):
    rescue_id: str
    node_id: str
    source: str
    rescue_kind: str
    confidence: float = Field(ge=0.0, le=1.0)
    automatically_applied: bool = True
    requires_review: bool = True
    evidence: list[str] = Field(default_factory=list)


class VerificationRecord(StrictModel):
    is_verified: bool = False
    verified_by: Literal["HUMAN"] | None = None
    verified_revision: int | None = None
    verified_at: datetime | None = None
    issue_count: int = Field(ge=0)
    critical_issue_count: int = Field(ge=0)
    unresolved_issues: list[str] = Field(default_factory=list)
    accepted_warnings: list[str] = Field(default_factory=list)


class ChangeOperation(StrictModel):
    operation_id: str
    revision: int = Field(ge=1)
    actor: Literal["VISION", "TOOL", "HUMAN"]
    action: str
    affected_ids: list[str] = Field(default_factory=list)
    note: str | None = None
    created_at: datetime


class GraphDocument(StrictModel):
    schema_version: Literal["1.0"] = "1.0"
    document_id: str
    revision: int = Field(default=1, ge=1)
    status: GraphStatus = GraphStatus.IN_REVIEW
    image_metadata: ImageMetadata
    nodes: list[GraphNode]
    edges: list[GraphEdge]
    ports: list[Port]
    issues: list[ReviewIssue] = Field(default_factory=list)
    rescues: list[RescueRecord] = Field(default_factory=list)
    verification: VerificationRecord
    retry_plan: list[str] = Field(default_factory=list)
    pipeline_metadata: dict[str, Any] = Field(default_factory=dict)
    audit_log: list[ChangeOperation] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_references(self) -> "GraphDocument":
        node_ids = {node.internal_id for node in self.nodes}
        port_ids = {port.port_id for port in self.ports}
        if len(node_ids) != len(self.nodes):
            raise ValueError("node internal_id values must be unique")
        if len(port_ids) != len(self.ports):
            raise ValueError("port_id values must be unique")
        for port in self.ports:
            if port.node_id not in node_ids:
                raise ValueError(f"port references unknown node: {port.node_id}")
        for edge in self.edges:
            if edge.source_node_id not in node_ids or edge.target_node_id not in node_ids:
                raise ValueError(f"edge references unknown node: {edge.internal_id}")
            if edge.source_port_id not in port_ids or edge.target_port_id not in port_ids:
                raise ValueError(f"edge references unknown port: {edge.internal_id}")
        return self

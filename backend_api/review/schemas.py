"""Pydantic schemas for SLD Review Pipeline and VerifiedSLD contract."""
from __future__ import annotations

from typing import Any, Dict, List, Optional

try:
    from pydantic import BaseModel, Field

    class ReviewImageMeta(BaseModel):
        width: int
        height: int
        url: str = ""

    class ReviewNode(BaseModel):
        id: str
        class_name: str = Field(..., alias="class")
        bbox: List[float] # [cx, cy, w, h] in original pixel coordinates
        confidence: float
        source: str
        review_status: str = "DETECTED" # 'DETECTED', 'SUSPICIOUS', 'CONFIRMED', 'REJECTED'
        review_reasons: List[str] = Field(default_factory=list)

        class Config:
            populate_by_name = True
            allow_population_by_field_name = True

    class ObjectReviewResult(BaseModel):
        document_id: str
        image: ReviewImageMeta
        nodes: List[Dict[str, Any]]
        status: str = "success"
        review_stage: str = "OBJECT_REVIEW"
        pipeline: Dict[str, Any] = Field(default_factory=dict)

    class ConfirmedNode(BaseModel):
        id: str
        class_name: str = Field(..., alias="class")
        bbox: List[float]
        confidence: float = 1.0
        source: str = "confirmed"
        review_status: str = "CONFIRMED"
        review_reasons: List[str] = Field(default_factory=list)

        class Config:
            populate_by_name = True
            allow_population_by_field_name = True

    class ConnectionReviewRequest(BaseModel):
        document_id: str
        confirmed_nodes: List[Dict[str, Any]]

    class ConnectionReviewResult(BaseModel):
        document_id: str
        nodes: List[Dict[str, Any]]
        lines: List[Dict[str, Any]]
        status: str = "success"
        review_stage: str = "CONNECTION_REVIEW"
        pipeline: Dict[str, Any] = Field(default_factory=dict)

    class AgentReviewNodeRequest(BaseModel):
        document_id: str
        node: Dict[str, Any]

    class CheckCompletenessRequest(BaseModel):
        document_id: str
        working_nodes: List[Dict[str, Any]]

    class VerifyObjectsGateRequest(BaseModel):
        document_id: str
        working_nodes: List[Dict[str, Any]]
        missing_candidates: List[Dict[str, Any]] = Field(default_factory=list)
        human_completeness_confirmed: bool = False

    class AgentReviewConnectionRequest(BaseModel):
        document_id: str
        line: Dict[str, Any]
        nodes: List[Dict[str, Any]] = Field(default_factory=list)
        lines: List[Dict[str, Any]] = Field(default_factory=list)

    class ValidateTopologyRequest(BaseModel):
        document_id: str
        nodes: List[Dict[str, Any]]
        lines: List[Dict[str, Any]]

    class VerifyFinalGateRequest(BaseModel):
        document_id: str
        working_nodes: List[Dict[str, Any]]
        working_lines: List[Dict[str, Any]]
        human_completeness_confirmed: bool = False

    class AgentChatRequest(BaseModel):
        document_id: str
        message: str
        stage: str = "OBJECT_REVIEW" # "OBJECT_REVIEW", "CONNECTION_REVIEW", "FINAL"
        selected_node: Optional[Dict[str, Any]] = None
        selected_line: Optional[Dict[str, Any]] = None
        working_nodes: List[Dict[str, Any]] = Field(default_factory=list)
        working_lines: List[Dict[str, Any]] = Field(default_factory=list)
        missing_candidates: List[Dict[str, Any]] = Field(default_factory=list)
        topology_issues: List[Dict[str, Any]] = Field(default_factory=list)
        history: List[Dict[str, str]] = Field(default_factory=list)

    class ProactiveSummaryRequest(BaseModel):
        document_id: str
        stage: str = "OBJECT_REVIEW"
        working_nodes: List[Dict[str, Any]] = Field(default_factory=list)
        working_lines: List[Dict[str, Any]] = Field(default_factory=list)
        missing_candidates: List[Dict[str, Any]] = Field(default_factory=list)
        topology_issues: List[Dict[str, Any]] = Field(default_factory=list)

    class VerifiedNode(BaseModel):
        id: str
        class_name: str = Field(..., alias="class")
        bbox: List[float]
        confidence: float
        source: str
        verification_status: str = "CONFIRMED"

        class Config:
            populate_by_name = True
            allow_population_by_field_name = True

    class VerifiedLine(BaseModel):
        line_id: str
        connected_to: List[str]
        path: List[List[float]] = Field(default_factory=list)
        source_port: str = "auto"
        target_port: str = "auto"
        trace_method: str = "electrical_graph"
        verification_status: str = "CONFIRMED"

    class VerifiedSLD(BaseModel):
        schema_version: str = "1.0"
        document_id: str
        status: str = "VERIFIED"
        image: ReviewImageMeta
        nodes: List[Dict[str, Any]]
        lines: List[Dict[str, Any]]
        verification: Dict[str, Any] = Field(default_factory=dict)

except ImportError:
    from dataclasses import dataclass, field

    @dataclass
    class ReviewImageMeta:
        width: int
        height: int
        url: str = ""

    @dataclass
    class ReviewNode:
        id: str
        class_name: str
        bbox: List[float]
        confidence: float
        source: str
        review_status: str = "DETECTED"
        review_reasons: List[str] = field(default_factory=list)

    @dataclass
    class ObjectReviewResult:
        document_id: str
        image: ReviewImageMeta
        nodes: List[Dict[str, Any]]
        status: str = "success"
        review_stage: str = "OBJECT_REVIEW"
        pipeline: Dict[str, Any] = field(default_factory=dict)

    @dataclass
    class ConfirmedNode:
        id: str
        class_name: str
        bbox: List[float]
        confidence: float = 1.0
        source: str = "confirmed"
        review_status: str = "CONFIRMED"
        review_reasons: List[str] = field(default_factory=list)

    @dataclass
    class ConnectionReviewRequest:
        document_id: str
        confirmed_nodes: List[Dict[str, Any]]

    @dataclass
    class ConnectionReviewResult:
        document_id: str
        nodes: List[Dict[str, Any]]
        lines: List[Dict[str, Any]]
        status: str = "success"
        review_stage: str = "CONNECTION_REVIEW"
        pipeline: Dict[str, Any] = field(default_factory=dict)

    @dataclass
    class AgentReviewNodeRequest:
        document_id: str
        node: Dict[str, Any]

    @dataclass
    class CheckCompletenessRequest:
        document_id: str
        working_nodes: List[Dict[str, Any]]

    @dataclass
    class VerifyObjectsGateRequest:
        document_id: str
        working_nodes: List[Dict[str, Any]]
        missing_candidates: List[Dict[str, Any]] = field(default_factory=list)
        human_completeness_confirmed: bool = False

    @dataclass
    class AgentReviewConnectionRequest:
        document_id: str
        line: Dict[str, Any]
        nodes: List[Dict[str, Any]] = field(default_factory=list)
        lines: List[Dict[str, Any]] = field(default_factory=list)

    @dataclass
    class ValidateTopologyRequest:
        document_id: str
        nodes: List[Dict[str, Any]]
        lines: List[Dict[str, Any]]

    @dataclass
    class VerifyFinalGateRequest:
        document_id: str
        working_nodes: List[Dict[str, Any]]
        working_lines: List[Dict[str, Any]]
        human_completeness_confirmed: bool = False

    @dataclass
    class AgentChatRequest:
        document_id: str
        message: str
        stage: str = "OBJECT_REVIEW"
        selected_node: Optional[Dict[str, Any]] = None
        selected_line: Optional[Dict[str, Any]] = None
        working_nodes: List[Dict[str, Any]] = field(default_factory=list)
        working_lines: List[Dict[str, Any]] = field(default_factory=list)
        missing_candidates: List[Dict[str, Any]] = field(default_factory=list)
        topology_issues: List[Dict[str, Any]] = field(default_factory=list)
        history: List[Dict[str, str]] = field(default_factory=list)

    @dataclass
    class VerifiedSLD:
        document_id: str
        image: ReviewImageMeta
        nodes: List[Dict[str, Any]]
        lines: List[Dict[str, Any]]
        schema_version: str = "1.0"
        status: str = "VERIFIED"
        verification: Dict[str, Any] = field(default_factory=dict)

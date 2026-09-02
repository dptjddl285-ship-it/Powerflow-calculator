"""FastAPI routes for GraphDocument review and verification."""

from __future__ import annotations

from typing import Literal
import uuid

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, ConfigDict

from agent_tools.vision_tools import (
    ReviewToolInputError,
    ReviewToolUnavailableError,
    review_tool_runner,
)
from agent.supervisor import ReviewAgentSupervisor
from agent.tool_registry import ReviewToolRegistry
from .agent_activity import ReviewAgentRun
from .graph_document import GraphDocument, ImageRegion, IssueStatus, ReviewIssue
from .patches import PatchPreview, PatchStatus
from .service import (
    IssueNotFoundError,
    PatchApplyError,
    RescueNotFoundError,
    ReviewConflictError,
    ReviewService,
)
from .store import (
    AnalysisAssetNotFoundError,
    AgentRunNotFoundError,
    DocumentAlreadyExistsError,
    DocumentNotFoundError,
    PatchNotFoundError,
    review_store,
)


class ReviewActionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    note: str | None = None
    selected_node_ids: list[str] | None = None


class RetryIssueRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    tool: Literal["auto", "roi_reanalysis", "port_aware_retry"] = "auto"
    object_only: bool = False


class CreateRoiIssueRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    roi: ImageRegion
    message: str | None = None


class DocumentSummary(BaseModel):
    document_id: str
    revision: int
    status: str
    filename: str | None
    node_count: int
    edge_count: int
    open_issue_count: int
    pending_rescue_count: int


class MissingObjectScanResponse(BaseModel):
    document: GraphDocument
    patch: PatchPreview


router = APIRouter(prefix="/review", tags=["review"])
service = ReviewService(review_store)
agent_supervisor = ReviewAgentSupervisor(
    store=review_store,
    registry=ReviewToolRegistry(review_tool_runner),
)


def _not_found(error: Exception) -> HTTPException:
    return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error))


def _conflict(error: Exception) -> HTTPException:
    return HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error))


def _find_issue(document: GraphDocument, issue_id: str) -> ReviewIssue:
    issue = next((item for item in document.issues if item.issue_id == issue_id), None)
    if issue is None:
        raise IssueNotFoundError(issue_id)
    return issue


@router.post(
    "/documents",
    response_model=GraphDocument,
    status_code=status.HTTP_201_CREATED,
)
def create_document(document: GraphDocument) -> GraphDocument:
    try:
        return review_store.put(document)
    except DocumentAlreadyExistsError as error:
        raise _conflict(error) from error


@router.get("/documents", response_model=list[DocumentSummary])
def list_documents() -> list[DocumentSummary]:
    summaries: list[DocumentSummary] = []
    for document in review_store.list():
        summaries.append(DocumentSummary(
            document_id=document.document_id,
            revision=document.revision,
            status=document.status.value,
            filename=document.image_metadata.filename,
            node_count=len(document.nodes),
            edge_count=len(document.edges),
            open_issue_count=sum(
                issue.status == IssueStatus.OPEN for issue in document.issues
            ),
            pending_rescue_count=sum(
                rescue.requires_review for rescue in document.rescues
            ),
        ))
    return summaries


@router.get("/documents/{document_id}", response_model=GraphDocument)
def get_document(document_id: str) -> GraphDocument:
    try:
        return review_store.get(document_id)
    except DocumentNotFoundError as error:
        raise _not_found(error) from error


@router.get(
    "/documents/{document_id}/issues",
    response_model=list[ReviewIssue],
)
def list_issues(
    document_id: str,
    issue_status: Literal["open", "resolved", "acknowledged"] | None = Query(
        default=None,
        alias="status",
    ),
) -> list[ReviewIssue]:
    try:
        document = review_store.get(document_id)
    except DocumentNotFoundError as error:
        raise _not_found(error) from error
    if issue_status is None:
        return document.issues
    return [issue for issue in document.issues if issue.status.value == issue_status]


@router.post(
    "/documents/{document_id}/issues",
    response_model=GraphDocument,
    status_code=status.HTTP_201_CREATED,
)
def create_roi_issue(
    document_id: str,
    request: CreateRoiIssueRequest,
) -> GraphDocument:
    try:
        return service.create_roi_issue(
            document_id,
            request.roi,
            message=request.message,
        )
    except DocumentNotFoundError as error:
        raise _not_found(error) from error
    except ReviewConflictError as error:
        raise _conflict(error) from error


@router.post(
    "/documents/{document_id}/issues/{issue_id}/retry",
    response_model=PatchPreview,
    status_code=status.HTTP_201_CREATED,
)
def retry_issue(
    document_id: str,
    issue_id: str,
    request: RetryIssueRequest,
) -> PatchPreview:
    try:
        document = review_store.get(document_id)
        issue = _find_issue(document, issue_id)
        if issue.status != IssueStatus.OPEN:
            raise ReviewConflictError("only an open issue can be retried")
        asset = review_store.get_analysis_asset(document_id)
        if request.object_only and request.tool == "port_aware_retry":
            raise ReviewConflictError(
                "port_aware_retry is unavailable in object-only review mode"
            )
        if request.tool == "auto":
            preview, _ = agent_supervisor.run(
                document=document,
                issue=issue,
                asset=asset,
                object_only=request.object_only,
            )
            return preview

        preview = review_tool_runner.create_preview(
            tool_name=request.tool,
            document=document,
            issue=issue,
            asset=asset,
        )
        if request.object_only:
            preview.operations = [
                operation
                for operation in preview.operations
                if operation.operation == "add_node"
            ]
            preview.status = PatchStatus.PENDING if preview.operations else PatchStatus.NO_CHANGE
            preview.summary = f"Object-only review found {len(preview.operations)} node candidate(s)"
        return review_store.put_patch(preview)
    except (DocumentNotFoundError, IssueNotFoundError) as error:
        raise _not_found(error) from error
    except AnalysisAssetNotFoundError as error:
        raise _conflict(
            ReviewConflictError("source image is unavailable for this document")
        ) from error
    except ReviewToolUnavailableError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(error),
        ) from error
    except (ReviewToolInputError, ReviewConflictError) as error:
        raise _conflict(error) from error


@router.get(
    "/documents/{document_id}/agent-runs",
    response_model=list[ReviewAgentRun],
)
def list_agent_runs(document_id: str) -> list[ReviewAgentRun]:
    try:
        return review_store.list_agent_runs(document_id)
    except DocumentNotFoundError as error:
        raise _not_found(error) from error


@router.get(
    "/documents/{document_id}/agent-runs/{run_id}",
    response_model=ReviewAgentRun,
)
def get_agent_run(document_id: str, run_id: str) -> ReviewAgentRun:
    try:
        run = review_store.get_agent_run(run_id)
        if run.document_id != document_id:
            raise AgentRunNotFoundError(run_id)
        return run
    except (DocumentNotFoundError, AgentRunNotFoundError) as error:
        raise _not_found(error) from error


@router.post(
    "/documents/{document_id}/missing-object-scan",
    response_model=MissingObjectScanResponse,
    status_code=status.HTTP_201_CREATED,
)
def scan_missing_objects(document_id: str) -> MissingObjectScanResponse:
    try:
        document = review_store.get(document_id)
        asset = review_store.get_analysis_asset(document_id)
        issue_id = f"issue_{uuid.uuid4().hex[:16]}"
        scan_issue = ReviewIssue(
            issue_id=issue_id,
            severity="warning",
            code="missing_object_candidates",
            message="Overlapping tile scan for objects missed by the primary detector",
            component_ids=[],
            roi=ImageRegion(
                x_min=0,
                y_min=0,
                x_max=float(document.image_metadata.width),
                y_max=float(document.image_metadata.height),
            ),
            suggested_tools=["roi_reanalysis"],
        )
        preview = review_tool_runner.create_missing_object_preview(
            document=document,
            issue=scan_issue,
            asset=asset,
        )
        if preview.status == PatchStatus.PENDING:
            document = service.register_missing_object_candidates(
                document_id,
                issue_id=issue_id,
                candidate_count=len(preview.operations),
            )
            preview.base_revision = document.revision
        preview = review_store.put_patch(preview)
        return MissingObjectScanResponse(document=document, patch=preview)
    except DocumentNotFoundError as error:
        raise _not_found(error) from error
    except AnalysisAssetNotFoundError as error:
        raise _conflict(
            ReviewConflictError("source image is unavailable for this document")
        ) from error
    except ReviewToolUnavailableError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(error),
        ) from error
    except (ReviewToolInputError, ReviewConflictError) as error:
        raise _conflict(error) from error


@router.get(
    "/documents/{document_id}/patches",
    response_model=list[PatchPreview],
)
def list_patches(document_id: str) -> list[PatchPreview]:
    try:
        return review_store.list_patches(document_id)
    except DocumentNotFoundError as error:
        raise _not_found(error) from error


@router.get(
    "/documents/{document_id}/patches/{patch_id}",
    response_model=PatchPreview,
)
def get_patch(document_id: str, patch_id: str) -> PatchPreview:
    try:
        patch = review_store.get_patch(patch_id)
        if patch.document_id != document_id:
            raise PatchNotFoundError(patch_id)
        return patch
    except (DocumentNotFoundError, PatchNotFoundError) as error:
        raise _not_found(error) from error


@router.post(
    "/documents/{document_id}/patches/{patch_id}/apply",
    response_model=GraphDocument,
)
def apply_patch(
    document_id: str,
    patch_id: str,
    request: ReviewActionRequest,
) -> GraphDocument:
    try:
        return service.apply_patch(
            document_id,
            patch_id,
            note=request.note,
            selected_node_ids=request.selected_node_ids,
        )
    except (DocumentNotFoundError, PatchNotFoundError) as error:
        raise _not_found(error) from error
    except PatchApplyError as error:
        raise _conflict(error) from error


@router.post(
    "/documents/{document_id}/patches/{patch_id}/reject",
    response_model=PatchPreview,
)
def reject_patch(
    document_id: str,
    patch_id: str,
    request: ReviewActionRequest,
) -> PatchPreview:
    del request  # Reserved for a future persisted reviewer note.
    try:
        return service.reject_patch(document_id, patch_id)
    except (DocumentNotFoundError, PatchNotFoundError) as error:
        raise _not_found(error) from error
    except PatchApplyError as error:
        raise _conflict(error) from error


def _change_issue(
    document_id: str,
    issue_id: str,
    target: IssueStatus,
    request: ReviewActionRequest,
) -> GraphDocument:
    try:
        return service.change_issue(
            document_id,
            issue_id,
            target,
            note=request.note,
        )
    except DocumentNotFoundError as error:
        raise _not_found(error) from error
    except IssueNotFoundError as error:
        raise _not_found(error) from error
    except ReviewConflictError as error:
        raise _conflict(error) from error


@router.post(
    "/documents/{document_id}/issues/{issue_id}/resolve",
    response_model=GraphDocument,
)
def resolve_issue(
    document_id: str,
    issue_id: str,
    request: ReviewActionRequest,
) -> GraphDocument:
    return _change_issue(document_id, issue_id, IssueStatus.RESOLVED, request)


@router.post(
    "/documents/{document_id}/issues/{issue_id}/acknowledge",
    response_model=GraphDocument,
)
def acknowledge_issue(
    document_id: str,
    issue_id: str,
    request: ReviewActionRequest,
) -> GraphDocument:
    return _change_issue(document_id, issue_id, IssueStatus.ACKNOWLEDGED, request)


@router.post(
    "/documents/{document_id}/issues/{issue_id}/reopen",
    response_model=GraphDocument,
)
def reopen_issue(
    document_id: str,
    issue_id: str,
    request: ReviewActionRequest,
) -> GraphDocument:
    return _change_issue(document_id, issue_id, IssueStatus.OPEN, request)


@router.post(
    "/documents/{document_id}/rescues/{rescue_id}/confirm",
    response_model=GraphDocument,
)
def confirm_rescue(
    document_id: str,
    rescue_id: str,
    request: ReviewActionRequest,
) -> GraphDocument:
    try:
        return service.confirm_rescue(document_id, rescue_id, note=request.note)
    except (DocumentNotFoundError, RescueNotFoundError) as error:
        raise _not_found(error) from error


@router.post(
    "/documents/{document_id}/verify",
    response_model=GraphDocument,
)
def verify_document(
    document_id: str,
    request: ReviewActionRequest,
) -> GraphDocument:
    try:
        return service.verify(document_id, note=request.note)
    except DocumentNotFoundError as error:
        raise _not_found(error) from error
    except ReviewConflictError as error:
        raise _conflict(error) from error


__all__ = ["router"]

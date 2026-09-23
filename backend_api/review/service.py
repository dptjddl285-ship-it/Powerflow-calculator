"""Lifecycle rules for reviewing and verifying GraphDocuments."""

from __future__ import annotations

from datetime import datetime, timezone
import uuid

from .graph_document import (
    ChangeOperation,
    GraphDocument,
    GraphStatus,
    ImageRegion,
    IssueStatus,
    ReviewIssue,
)
from .patches import PatchPreview, PatchStatus
from .store import PatchNotFoundError, ReviewStore


class ReviewConflictError(Exception):
    pass


class IssueNotFoundError(Exception):
    pass


class RescueNotFoundError(Exception):
    pass


class PatchApplyError(Exception):
    pass


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _operation_id() -> str:
    return f"op_{uuid.uuid4().hex[:16]}"


def _refresh_verification(document: GraphDocument) -> None:
    open_issues = [issue for issue in document.issues if issue.status == IssueStatus.OPEN]
    document.verification.issue_count = len(document.issues)
    document.verification.critical_issue_count = sum(
        issue.severity == "error" for issue in open_issues
    )
    document.verification.unresolved_issues = [issue.issue_id for issue in open_issues]
    document.verification.accepted_warnings = [
        issue.issue_id
        for issue in document.issues
        if issue.severity == "warning" and issue.status == IssueStatus.ACKNOWLEDGED
    ]


def _append_unconnected_candidate_issues(
    document: GraphDocument,
    added_node_ids: list[str],
) -> None:
    """Keep node-only rescues reviewable after their add patch is accepted."""
    connected_ids = {
        node_id
        for edge in document.edges
        for node_id in (edge.source_node_id, edge.target_node_id)
    }
    nodes = {node.internal_id: node for node in document.nodes}
    existing_components = {
        component_id
        for issue in document.issues
        if issue.status == IssueStatus.OPEN
        and issue.code in {"suspicious_added_bus", "unconnected_added_candidate"}
        for component_id in issue.component_ids
    }
    for node_id in added_node_ids:
        node = nodes.get(node_id)
        if node is None or node_id in connected_ids or node_id in existing_components:
            continue
        candidate = node.parameters.get("review_candidate")
        if not isinstance(candidate, dict) or candidate.get("kind") != "missing_object":
            continue
        if node.type == "bus":
            code = "suspicious_added_bus"
            message = (
                "Added bus candidate has no electrical port or connected device; "
                "verify that a conductor segment was not mistaken for a bus"
            )
        else:
            code = "unconnected_added_candidate"
            message = (
                "Added object candidate has no electrical connection and needs "
                "a local port-aware review"
            )
        document.issues.append(ReviewIssue(
            issue_id=f"issue_{uuid.uuid4().hex[:16]}",
            severity="warning",
            code=code,
            message=message,
            component_ids=[node_id],
            suggested_tools=["roi_reanalysis"],
        ))


def _invalidate_verification(document: GraphDocument) -> None:
    document.status = GraphStatus.IN_REVIEW
    document.verification.is_verified = False
    document.verification.verified_by = None
    document.verification.verified_revision = None
    document.verification.verified_at = None


def _append_operation(
    document: GraphDocument,
    *,
    action: str,
    affected_ids: list[str],
    note: str | None,
) -> None:
    document.audit_log.append(ChangeOperation(
        operation_id=_operation_id(),
        revision=document.revision,
        actor="HUMAN",
        action=action,
        affected_ids=affected_ids,
        note=note,
        created_at=_now(),
    ))


class ReviewService:
    def __init__(self, store: ReviewStore):
        self.store = store

    def change_issue(
        self,
        document_id: str,
        issue_id: str,
        target: IssueStatus,
        *,
        note: str | None = None,
    ) -> GraphDocument:
        document = self.store.get(document_id)
        issue = next((item for item in document.issues if item.issue_id == issue_id), None)
        if issue is None:
            raise IssueNotFoundError(issue_id)
        if target == IssueStatus.ACKNOWLEDGED and issue.severity == "error":
            raise ReviewConflictError("error issues must be resolved, not acknowledged")
        if issue.status == target:
            return document

        issue.status = target
        document.revision += 1
        _invalidate_verification(document)
        _refresh_verification(document)
        _append_operation(
            document,
            action=f"issue_{target.value}",
            affected_ids=[issue_id, *issue.component_ids],
            note=note,
        )
        return self.store.replace(document)

    def create_roi_issue(
        self,
        document_id: str,
        roi: ImageRegion,
        *,
        message: str | None = None,
    ) -> GraphDocument:
        document = self.store.get(document_id)
        image_width = document.image_metadata.width
        image_height = document.image_metadata.height
        if image_width > 0 and roi.x_max > image_width:
            raise ReviewConflictError("ROI exceeds original image width")
        if image_height > 0 and roi.y_max > image_height:
            raise ReviewConflictError("ROI exceeds original image height")
        if roi.x_max - roi.x_min < 8 or roi.y_max - roi.y_min < 8:
            raise ReviewConflictError("ROI must be at least 8 x 8 pixels")

        issue = ReviewIssue(
            issue_id=f"issue_{uuid.uuid4().hex[:16]}",
            severity="warning",
            code="user_missing_component_roi",
            message=message or "User marked this ROI for missing-component reanalysis",
            component_ids=[],
            roi=roi,
            suggested_tools=["roi_reanalysis"],
        )
        document.issues.append(issue)
        document.revision += 1
        _invalidate_verification(document)
        _refresh_verification(document)
        _append_operation(
            document,
            action="roi_issue_created",
            affected_ids=[issue.issue_id],
            note=message,
        )
        return self.store.replace(document)

    def register_missing_object_candidates(
        self,
        document_id: str,
        *,
        issue_id: str,
        candidate_count: int,
    ) -> GraphDocument:
        document = self.store.get(document_id)
        issue = ReviewIssue(
            issue_id=issue_id,
            severity="warning",
            code="missing_object_candidates",
            message=f"Tile reanalysis found {candidate_count} missing-object candidate(s)",
            component_ids=[],
            suggested_tools=["roi_reanalysis"],
        )
        document.issues.append(issue)
        document.revision += 1
        _invalidate_verification(document)
        _refresh_verification(document)
        _append_operation(
            document,
            action="missing_object_candidates_created",
            affected_ids=[issue.issue_id],
            note=f"candidate_count={candidate_count}",
        )
        return self.store.replace(document)

    def confirm_rescue(
        self,
        document_id: str,
        rescue_id: str,
        *,
        note: str | None = None,
    ) -> GraphDocument:
        document = self.store.get(document_id)
        rescue = next((item for item in document.rescues if item.rescue_id == rescue_id), None)
        if rescue is None:
            raise RescueNotFoundError(rescue_id)
        if not rescue.requires_review:
            return document

        rescue.requires_review = False
        document.revision += 1
        _invalidate_verification(document)
        _refresh_verification(document)
        _append_operation(
            document,
            action="rescue_confirmed",
            affected_ids=[rescue_id, rescue.node_id],
            note=note,
        )
        return self.store.replace(document)

    def verify(
        self,
        document_id: str,
        *,
        note: str | None = None,
    ) -> GraphDocument:
        document = self.store.get(document_id)
        _refresh_verification(document)
        open_issues = [issue for issue in document.issues if issue.status == IssueStatus.OPEN]
        pending_rescues = [rescue for rescue in document.rescues if rescue.requires_review]
        blockers: list[str] = []
        if not document.nodes:
            blockers.append("document has no detected nodes")
        if open_issues:
            blockers.append(f"{len(open_issues)} review issue(s) remain open")
        if pending_rescues:
            blockers.append(f"{len(pending_rescues)} automatic rescue(s) need confirmation")
        if blockers:
            raise ReviewConflictError("; ".join(blockers))

        if document.status == GraphStatus.VERIFIED:
            return document
        document.revision += 1
        document.status = GraphStatus.VERIFIED
        document.verification.is_verified = True
        document.verification.verified_by = "HUMAN"
        document.verification.verified_revision = document.revision
        document.verification.verified_at = _now()
        _append_operation(
            document,
            action="document_verified",
            affected_ids=[document.document_id],
            note=note,
        )
        return self.store.replace(document)

    @staticmethod
    def _remove_edge(document: GraphDocument, edge_id: str) -> None:
        edge = next((item for item in document.edges if item.internal_id == edge_id), None)
        if edge is None:
            raise PatchApplyError(f"edge not found: {edge_id}")
        removed_port_ids = {edge.source_port_id, edge.target_port_id}
        document.edges = [item for item in document.edges if item.internal_id != edge_id]
        document.ports = [item for item in document.ports if item.port_id not in removed_port_ids]
        for node in document.nodes:
            node.ports = [port_id for port_id in node.ports if port_id not in removed_port_ids]

    def apply_patch(
        self,
        document_id: str,
        patch_id: str,
        *,
        note: str | None = None,
        selected_node_ids: list[str] | None = None,
    ) -> GraphDocument:
        document = self.store.get(document_id)
        patch = self.store.get_patch(patch_id)
        if patch.document_id != document_id:
            raise PatchApplyError("patch belongs to a different document")
        if patch.status != PatchStatus.PENDING:
            raise PatchApplyError(f"patch is not pending: {patch.status.value}")
        if patch.base_revision != document.revision:
            raise PatchApplyError(
                f"stale patch base revision {patch.base_revision}; current revision is {document.revision}"
            )

        selected_ids: set[str] | None = None
        if selected_node_ids is not None:
            if patch.tool_name != "missing_object_scan":
                raise PatchApplyError(
                    "selected_node_ids is only supported for missing-object patches"
                )
            selected_ids = set(selected_node_ids)
            if not selected_ids:
                raise PatchApplyError("at least one missing-object candidate must be selected")
            candidate_ids = {
                operation.node.internal_id
                for operation in patch.operations
                if operation.operation == "add_node" and operation.node is not None
            }
            unknown_ids = selected_ids - candidate_ids
            if unknown_ids:
                raise PatchApplyError(
                    "selected candidate is not part of this patch: "
                    + ", ".join(sorted(unknown_ids))
                )

        affected_ids: list[str] = [patch.patch_id, patch.issue_id]
        added_node_ids: list[str] = []
        for operation in patch.operations:
            if operation.operation == "add_node":
                assert operation.node is not None
                if (
                    selected_ids is not None
                    and operation.node.internal_id not in selected_ids
                ):
                    continue
                if any(node.internal_id == operation.node.internal_id for node in document.nodes):
                    raise PatchApplyError(f"node already exists: {operation.node.internal_id}")
                document.nodes.append(operation.node.model_copy(deep=True))
                affected_ids.append(operation.node.internal_id)
                added_node_ids.append(operation.node.internal_id)
                continue

            if operation.operation in {"remove_edge", "replace_edge"}:
                assert operation.target_id is not None
                self._remove_edge(document, operation.target_id)
                affected_ids.append(operation.target_id)
                if operation.operation == "remove_edge":
                    continue

            if operation.operation in {"add_edge", "replace_edge"}:
                assert operation.edge is not None
                edge = operation.edge.model_copy(deep=True)
                if any(item.internal_id == edge.internal_id for item in document.edges):
                    raise PatchApplyError(f"edge already exists: {edge.internal_id}")
                node_ids = {node.internal_id for node in document.nodes}
                if edge.source_node_id not in node_ids or edge.target_node_id not in node_ids:
                    raise PatchApplyError(f"edge has unknown node endpoint: {edge.internal_id}")
                existing_port_ids = {port.port_id for port in document.ports}
                if any(port.port_id in existing_port_ids for port in operation.ports):
                    raise PatchApplyError(f"edge has duplicate port id: {edge.internal_id}")
                document.ports.extend(port.model_copy(deep=True) for port in operation.ports)
                document.edges.append(edge)
                by_id = {node.internal_id: node for node in document.nodes}
                by_id[edge.source_node_id].ports.append(edge.source_port_id)
                by_id[edge.target_node_id].ports.append(edge.target_port_id)
                affected_ids.append(edge.internal_id)

        issue = next((item for item in document.issues if item.issue_id == patch.issue_id), None)
        if issue is None:
            raise PatchApplyError(f"patch issue no longer exists: {patch.issue_id}")
        issue.status = IssueStatus.RESOLVED
        _append_unconnected_candidate_issues(document, added_node_ids)
        document.revision += 1
        _invalidate_verification(document)
        _refresh_verification(document)
        _append_operation(
            document,
            action=f"patch_applied:{patch.tool_name}",
            affected_ids=affected_ids,
            note=note,
        )
        # Re-validate all graph references before replacing the stored document.
        validated = GraphDocument.model_validate(document.model_dump())
        stored = self.store.replace(validated)
        patch.status = PatchStatus.APPLIED
        patch.decided_at = _now()
        self.store.replace_patch(patch)
        return stored

    def reject_patch(
        self,
        document_id: str,
        patch_id: str,
    ) -> PatchPreview:
        self.store.get(document_id)
        patch = self.store.get_patch(patch_id)
        if patch.document_id != document_id:
            raise PatchApplyError("patch belongs to a different document")
        if patch.status != PatchStatus.PENDING:
            raise PatchApplyError(f"patch is not pending: {patch.status.value}")
        patch.status = PatchStatus.REJECTED
        patch.decided_at = _now()
        return self.store.replace_patch(patch)


__all__ = [
    "IssueNotFoundError",
    "PatchApplyError",
    "PatchNotFoundError",
    "RescueNotFoundError",
    "ReviewConflictError",
    "ReviewService",
]

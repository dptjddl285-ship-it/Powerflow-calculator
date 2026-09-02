"""Bounded Review Agent orchestration over existing deterministic CV tools."""

from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
from typing import Any
import uuid

from core.pipeline_policy import validate_graph
from review.agent_activity import (
    AgentActivityEntry,
    AgentRunStatus,
    AgentToolEvaluation,
    ReviewAgentRun,
)
from review.graph_document import GraphDocument, ReviewIssue
from review.patches import PatchOperation, PatchPreview, PatchStatus
from review.store import AnalysisAsset, ReviewStore

from .review_planning_provider import (
    LocalRulePlanningProvider,
    ReviewPlanningContext,
    ReviewPlanningProvider,
)
from .tool_registry import ReviewToolRegistry


MAX_AGENT_ATTEMPTS = 2


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _degrees(document: GraphDocument) -> dict[str, int]:
    result = {node.internal_id: 0 for node in document.nodes}
    for edge in document.edges:
        result[edge.source_node_id] = result.get(edge.source_node_id, 0) + 1
        result[edge.target_node_id] = result.get(edge.target_node_id, 0) + 1
    return result


def _legacy_graph(document: GraphDocument) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    ports = {port.port_id: port for port in document.ports}
    nodes = [{
        "id": node.internal_id,
        "class": node.type,
        "bbox": [
            node.bbox.center_x,
            node.bbox.center_y,
            node.bbox.width,
            node.bbox.height,
        ],
        "metadata": deepcopy(node.parameters.get("metadata", {})),
    } for node in document.nodes]
    lines: list[dict[str, Any]] = []
    for edge in document.edges:
        source_port = ports.get(edge.source_port_id)
        target_port = ports.get(edge.target_port_id)
        lines.append({
            "line_id": edge.internal_id,
            "connected_to": [edge.source_node_id, edge.target_node_id],
            "path": [[point.x, point.y] for point in edge.path],
            "source_port": source_port.side if source_port else "boundary",
            "target_port": target_port.side if target_port else "boundary",
        })
    return nodes, lines


def _topology_issues(document: GraphDocument) -> list[dict[str, Any]]:
    nodes, lines = _legacy_graph(document)
    return [issue.to_dict() for issue in validate_graph(nodes, lines)]


def _issue_score(issues: list[dict[str, Any]]) -> int:
    weights = {"error": 10, "warning": 3, "info": 1}
    return sum(weights.get(str(issue.get("severity", "warning")), 3) for issue in issues)


def _target_issue_count(
    issues: list[dict[str, Any]],
    issue: ReviewIssue,
) -> int:
    wanted = set(issue.component_ids)
    return sum(
        str(item.get("code")) == issue.code
        and (
            not wanted
            or bool(wanted & {str(value) for value in item.get("component_ids", [])})
        )
        for item in issues
    )


def _apply_operations_to_copy(
    document: GraphDocument,
    operations: list[PatchOperation],
) -> GraphDocument:
    candidate = document.model_copy(deep=True)
    by_id = {node.internal_id: node for node in candidate.nodes}
    for operation in operations:
        if operation.operation == "add_node":
            assert operation.node is not None
            candidate.nodes.append(operation.node.model_copy(deep=True))
            by_id[operation.node.internal_id] = candidate.nodes[-1]
            continue
        if operation.operation in {"remove_edge", "replace_edge"}:
            assert operation.target_id is not None
            removed = next(
                (edge for edge in candidate.edges if edge.internal_id == operation.target_id),
                None,
            )
            if removed is not None:
                removed_ports = {removed.source_port_id, removed.target_port_id}
                candidate.edges = [
                    edge for edge in candidate.edges
                    if edge.internal_id != operation.target_id
                ]
                candidate.ports = [
                    port for port in candidate.ports
                    if port.port_id not in removed_ports
                ]
                for node in candidate.nodes:
                    node.ports = [port for port in node.ports if port not in removed_ports]
            if operation.operation == "remove_edge":
                continue
        if operation.operation in {"add_edge", "replace_edge"}:
            assert operation.edge is not None
            edge = operation.edge.model_copy(deep=True)
            candidate.ports.extend(port.model_copy(deep=True) for port in operation.ports)
            candidate.edges.append(edge)
            by_id[edge.source_node_id].ports.append(edge.source_port_id)
            by_id[edge.target_node_id].ports.append(edge.target_port_id)
    return GraphDocument.model_validate(candidate.model_dump())


def _filter_object_only(preview: PatchPreview) -> PatchPreview:
    filtered = preview.model_copy(deep=True)
    filtered.operations = [
        operation for operation in filtered.operations
        if operation.operation == "add_node"
    ]
    filtered.status = PatchStatus.PENDING if filtered.operations else PatchStatus.NO_CHANGE
    filtered.summary = f"Object-only review found {len(filtered.operations)} node candidate(s)"
    return filtered


class _ActivityWriter:
    def __init__(self) -> None:
        self.entries: list[AgentActivityEntry] = []

    def add(
        self,
        event: str,
        message: str,
        *,
        tool_name: str | None = None,
        reason: str | None = None,
        patch_id: str | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        self.entries.append(AgentActivityEntry(
            sequence=len(self.entries) + 1,
            event=event,
            message=message,
            tool_name=tool_name,
            reason=reason,
            patch_id=patch_id,
            details=details or {},
            created_at=_now(),
        ))


class ReviewAgentSupervisor:
    """Plans and evaluates at most two preview-only Review Tool attempts."""

    def __init__(
        self,
        *,
        store: ReviewStore,
        registry: ReviewToolRegistry,
        provider: ReviewPlanningProvider | None = None,
        max_attempts: int = MAX_AGENT_ATTEMPTS,
    ) -> None:
        self.store = store
        self.registry = registry
        self.provider = provider or LocalRulePlanningProvider()
        self.max_attempts = min(max(1, max_attempts), MAX_AGENT_ATTEMPTS)

    def _context(
        self,
        document: GraphDocument,
        issue: ReviewIssue,
        *,
        object_only: bool,
    ) -> ReviewPlanningContext:
        candidates = self.registry.candidates(
            document=document,
            issue=issue,
            object_only=object_only,
        )
        degrees = _degrees(document)
        affected = [
            {
                "node_id": node.internal_id,
                "type": node.type,
                "degree": degrees.get(node.internal_id, 0),
                "port_count": len(node.ports),
                "confidence": node.confidence,
            }
            for node in document.nodes
            if node.internal_id in set(issue.component_ids)
        ]
        return ReviewPlanningContext(
            issue=issue,
            graph_summary={
                "revision": document.revision,
                "node_count": len(document.nodes),
                "edge_count": len(document.edges),
                "open_issue_count": sum(item.status.value == "open" for item in document.issues),
                "affected_nodes": affected,
                "tool_reasons": {item.name: item.reason for item in candidates},
            },
            available_tools=tuple(item.name for item in candidates),
            object_only=object_only,
        )

    @staticmethod
    def _evaluate(
        *,
        document: GraphDocument,
        issue: ReviewIssue,
        preview: PatchPreview,
        attempt: int,
        object_only: bool,
    ) -> AgentToolEvaluation:
        before_issues = _topology_issues(document)
        before_score = _issue_score(before_issues)
        target_before = _target_issue_count(before_issues, issue)
        try:
            candidate = _apply_operations_to_copy(document, preview.operations)
            after_issues = _topology_issues(candidate)
            valid_candidate = True
        except (AssertionError, KeyError, ValueError) as error:
            after_issues = before_issues
            valid_candidate = False
            validation_error = str(error)
        after_score = _issue_score(after_issues)
        target_after = _target_issue_count(after_issues, issue)
        operation_count = len(preview.operations)
        missing_component_issue = issue.code in {
            "user_missing_component_roi",
            "missing_object_candidates",
        }
        adds_node = any(item.operation == "add_node" for item in preview.operations)
        target_improved = target_after < target_before
        topology_improved = after_score < before_score
        improved = bool(
            valid_candidate
            and preview.status == PatchStatus.PENDING
            and operation_count
            and (
                target_improved
                or topology_improved
                or ((missing_component_issue or object_only) and adds_node)
            )
        )
        if improved:
            reason = "대상 Issue 또는 전체 토폴로지 점수가 개선됨"
        elif not valid_candidate:
            reason = f"가상 적용 후 Graph 검증 실패: {validation_error}"
        elif operation_count == 0:
            reason = "변경 후보를 찾지 못함"
        else:
            reason = "변경 후보는 있으나 대상 Issue와 토폴로지가 개선되지 않음"
        return AgentToolEvaluation(
            attempt=attempt,
            tool_name=preview.tool_name,
            patch_id=preview.patch_id,
            patch_status=preview.status.value,
            improved=improved,
            before_score=before_score,
            after_score=after_score,
            target_issue_before=target_before,
            target_issue_after=target_after,
            operation_count=operation_count,
            reason=reason,
            metrics={
                "before_issue_count": len(before_issues),
                "after_issue_count": len(after_issues),
                "node_additions": sum(item.operation == "add_node" for item in preview.operations),
                "edge_additions": sum(item.operation == "add_edge" for item in preview.operations),
            },
        )

    def run(
        self,
        *,
        document: GraphDocument,
        issue: ReviewIssue,
        asset: AnalysisAsset,
        object_only: bool = False,
    ) -> tuple[PatchPreview, ReviewAgentRun]:
        started = _now()
        run_id = f"agent_run_{uuid.uuid4().hex[:16]}"
        log = _ActivityWriter()
        log.add(
            "issue_detected",
            f"Issue {issue.code} 감지",
            reason=issue.message,
            details={"component_ids": issue.component_ids, "severity": issue.severity},
        )
        context = self._context(document, issue, object_only=object_only)
        plan = self.provider.build_plan(
            document=document,
            context=context,
            max_attempts=self.max_attempts,
        )
        log.add(
            "plan_created",
            f"최대 {len(plan)}회 실행 계획 생성",
            details={"tools": [step.tool_name for step in plan]},
        )

        evaluations: list[AgentToolEvaluation] = []
        generated: list[PatchPreview] = []
        selected: PatchPreview | None = None
        for index, step in enumerate(plan):
            log.add(
                "tool_selected",
                f"{step.attempt}차 도구 선택: {step.tool_name}",
                tool_name=step.tool_name,
                reason=step.reason,
            )
            preview = self.registry.execute(
                tool_name=step.tool_name,
                document=document,
                issue=issue,
                asset=asset,
            )
            if object_only:
                preview = _filter_object_only(preview)
            generated.append(preview)
            log.add(
                "tool_completed",
                preview.summary,
                tool_name=step.tool_name,
                patch_id=preview.patch_id,
                details={"operation_count": len(preview.operations)},
            )
            evaluation = self._evaluate(
                document=document,
                issue=issue,
                preview=preview,
                attempt=step.attempt,
                object_only=object_only,
            )
            evaluations.append(evaluation)
            log.add(
                "result_evaluated",
                evaluation.reason,
                tool_name=step.tool_name,
                patch_id=preview.patch_id,
                details=evaluation.model_dump(mode="json"),
            )
            if evaluation.improved:
                selected = preview
                break
            if index + 1 < len(plan):
                log.add(
                    "retry_scheduled",
                    "개선이 없어 대체 도구를 1회 추가 시도",
                    reason=evaluation.reason,
                    details={"next_tool": plan[index + 1].tool_name},
                )

        if selected is not None:
            selected.analysis_snapshot = {
                **selected.analysis_snapshot,
                "agent_run_id": run_id,
                "agent_attempts": len(evaluations),
                "agent_evaluation": evaluations[-1].model_dump(mode="json"),
            }
            final_patch = selected
            status = AgentRunStatus.AWAITING_APPROVAL
            selected_patch_id = final_patch.patch_id
            log.add(
                "final_decision",
                "개선된 수정 후보를 사용자 승인 대기 상태로 전달",
                patch_id=final_patch.patch_id,
            )
        else:
            if not generated:
                raise RuntimeError("Review Agent plan contains no executable tool")
            final_patch = generated[-1].model_copy(deep=True)
            final_patch.operations = []
            final_patch.status = PatchStatus.NO_CHANGE
            final_patch.summary = "Agent가 최대 2회 검토했지만 유의미한 개선 후보를 찾지 못했습니다"
            final_patch.analysis_snapshot = {
                **final_patch.analysis_snapshot,
                "agent_run_id": run_id,
                "agent_attempts": len(evaluations),
                "agent_evaluations": [item.model_dump(mode="json") for item in evaluations],
            }
            status = AgentRunStatus.NO_IMPROVEMENT
            selected_patch_id = None
            log.add(
                "final_decision",
                "최대 재시도 후 개선 후보 없음",
                patch_id=final_patch.patch_id,
            )

        stored_patch = self.store.put_patch(final_patch)
        log.add(
            "patch_registered",
            "최종 비교 결과를 Patch 저장소에 등록",
            patch_id=stored_patch.patch_id,
            details={"status": stored_patch.status.value},
        )
        run = ReviewAgentRun(
            run_id=run_id,
            document_id=document.document_id,
            issue_id=issue.issue_id,
            base_revision=document.revision,
            provider=self.provider.name,
            status=status,
            plan=plan,
            evaluations=evaluations,
            activity_log=log.entries,
            selected_patch_id=selected_patch_id,
            created_at=started,
            completed_at=_now(),
        )
        return stored_patch, self.store.put_agent_run(run)


__all__ = ["MAX_AGENT_ATTEMPTS", "ReviewAgentSupervisor"]

"""Staged object/completeness/connection review API adopted from the handoff branch.

It deliberately reuses the active PowerLens CV and source-pixel topology functions.
"""
from __future__ import annotations

from collections.abc import Callable
from typing import Any

from fastapi import APIRouter, File, Response, UploadFile

import core.env_loader
from core.adaptive_vision_pipeline import (
    detect_sld_connections_adaptive,
    detect_sld_objects_adaptive,
)
from core.bus_number_linker import (
    link_and_validate_bus_numbers,
    propagate_bus_numbers_to_devices,
    synchronize_node_and_line_ids,
)
from core.pipeline_policy import validate_graph
from review.session_store import session_store
from review.schemas import (
    AgentChatRequest,
    AgentReviewConnectionRequest,
    AgentReviewNodeRequest,
    CheckCompletenessRequest,
    ConnectionReviewRequest,
    LinkBusNumbersRequest,
    ProactiveSummaryRequest,
    TraceConnectionCandidateRequest,
    ValidateTopologyRequest,
    VerifyFinalGateRequest,
    VerifyObjectsGateRequest,
)
from agent import (
    chat_reviewer,
    classify_suspicious,
    completeness_reviewer,
    connection_verifier,
    extract_all_connections_evidence,
    extract_connection_evidence,
    extract_object_evidence,
    generate_display_labels,
    generate_line_display_labels,
    get_assistant_provider,
    object_reviewer,
)

router = APIRouter()
_model_provider: Callable[[], Any] | None = None


def configure_staged_review_model(provider: Callable[[], Any]) -> None:
    global _model_provider
    _model_provider = provider


def _require_model() -> Any:
    if _model_provider is None or _model_provider() is None:
        raise RuntimeError("Vision model is not loaded")
    return _model_provider()


@router.post("/review/detect_objects")
async def review_detect_objects(file: UploadFile = File(...)):
    print(f"\n🔍 [Review: 객체 검출 수신] 파일명: {file.filename}")
    try:
        image_bytes = await file.read()
        content_type = file.content_type or "image/png"
        session = session_store.create_session(image_bytes, content_type=content_type)

        result_data = detect_sld_objects_adaptive(image_bytes, _require_model())
        raw_nodes = result_data.get("nodes", [])
        annotated_nodes = classify_suspicious(raw_nodes)
        annotated_nodes = generate_display_labels(annotated_nodes)

        suspicious_count = sum(
            1 for n in annotated_nodes if n.get("review_status") == "SUSPICIOUS"
        )
        detected_count = sum(
            1 for n in annotated_nodes if n.get("review_status") == "DETECTED"
        )

        proactive_summary = get_assistant_provider().generate_proactive_summary(
            document_id=session.document_id,
            stage="OBJECT_REVIEW",
            working_nodes=annotated_nodes,
        )

        return {
            "status": "success",
            "document_id": session.document_id,
            "review_stage": "OBJECT_REVIEW",
            "image": {
                "width": session.width,
                "height": session.height,
                "url": f"/review/image/{session.document_id}",
            },
            "nodes": annotated_nodes,
            "proactive_summary": proactive_summary,
            "review_summary": {
                "total": len(annotated_nodes),
                "suspicious": suspicious_count,
                "detected": detected_count,
                "confirmed": 0,
            },
            "pipeline": result_data.get("pipeline", {}),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 🖼️ [Review API 2] 원본 이미지 조회
# ==========================================
@router.get("/review/image/{document_id}")
async def review_get_image(document_id: str):
    session = session_store.get_session(document_id)
    if session is None:
        return Response(
            status_code=404,
            content="Image session not found or expired",
            media_type="text/plain",
        )
    return Response(content=session.image_bytes, media_type=session.content_type)


# ==========================================
# 🤖 [Review API 3] Agent 객체 검수 및 한국어 설명
# ==========================================
@router.post("/review/agent_review_node")
async def review_agent_node(request: AgentReviewNodeRequest):
    print(f"\n🤖 [Agent Review 요청] Document: {request.document_id}, Node: {request.node.get('id')}")
    try:
        session = session_store.get_session(request.document_id)
        img = None
        if session:
            import cv2
            import numpy as np
            img = cv2.imdecode(np.frombuffer(session.image_bytes, np.uint8), cv2.IMREAD_COLOR)

        evidence = extract_object_evidence(request.node)
        review_res = object_reviewer.review_object(evidence, image=img)
        return {
            "status": "success",
            "document_id": request.document_id,
            "node_id": request.node.get("id"),
            "result": review_res.to_dict(),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 🌐 [Review API 3.5] Global Diagram Completeness Review
# ==========================================
@router.post("/review/check_completeness")
async def review_check_completeness(request: CheckCompletenessRequest):
    print(f"\n🌐 [Global Completeness Review 요청] Document: {request.document_id}, Working nodes: {len(request.working_nodes)}")
    try:
        session = session_store.get_session(request.document_id)
        img = None
        image_bytes = None
        if session:
            import cv2
            import numpy as np
            image_bytes = session.image_bytes
            img = cv2.imdecode(np.frombuffer(session.image_bytes, np.uint8), cv2.IMREAD_COLOR)

        result = completeness_reviewer.review_completeness(
            working_nodes=request.working_nodes,
            image=img,
            image_bytes=image_bytes,
        )
        return {
            "status": "success",
            "document_id": request.document_id,
            "result": result.to_dict(),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 🚪 [Review API 4] Object Gate 검증
# ==========================================
@router.post("/review/verify_objects_gate")
async def review_verify_objects_gate(request: VerifyObjectsGateRequest):
    print(
        f"\n🚪 [Object Gate 검증 요청] Document: {request.document_id}, "
        f"Working nodes: {len(request.working_nodes)}, "
        f"Missing Candidates: {len(request.missing_candidates)}, "
        f"Human Completeness: {request.human_completeness_confirmed}"
    )
    try:
        confirmed_nodes = []
        suspicious_nodes = []

        for node in request.working_nodes:
            status = str(node.get("review_status", "")).upper()
            if status == "REJECTED":
                continue
            elif status == "SUSPICIOUS":
                suspicious_nodes.append(node)
            else:
                # Both CONFIRMED and clean DETECTED are accepted as resolved/confirmed
                node_copy = dict(node)
                if status == "DETECTED":
                    node_copy["review_status"] = "CONFIRMED"
                    node_copy["source"] = f"{node_copy.get('source', 'cv')}_auto_confirmed"
                confirmed_nodes.append(node_copy)

        # 1. Check unresolved suspicious nodes
        if len(suspicious_nodes) > 0 or len(confirmed_nodes) == 0:
            return {
                "status": "success",
                "gate_status": "BLOCKED",
                "document_id": request.document_id,
                "confirmed_nodes": confirmed_nodes,
                "unconfirmed_count": len(suspicious_nodes),
                "unconfirmed_node_ids": [n.get("id") for n in suspicious_nodes],
                "message": f"검토 필요(SUSPICIOUS) 객체 {len(suspicious_nodes)}건이 남아있어 결선 단계로 진행할 수 없습니다. (승인/클래스변경/제외 필요)",
            }

        # 2. Check unresolved missing candidates (must be RESOLVED_BY_MANUAL_ADD or DISMISSED_BY_HUMAN)
        unresolved_candidates = [
            c for c in request.missing_candidates
            if str(c.get("status", "")).upper() == "OPEN"
        ]
        if len(unresolved_candidates) > 0:
            return {
                "status": "success",
                "gate_status": "BLOCKED",
                "document_id": request.document_id,
                "confirmed_nodes": confirmed_nodes,
                "unresolved_candidate_count": len(unresolved_candidates),
                "message": f"누락 가능성 후보 {len(unresolved_candidates)}건이 해결되지 않았습니다. [객체 수동 추가] 또는 [문제 없음(Dismiss)]을 완료해 주세요.",
            }

        # 3. Check human completeness confirmation
        if not request.human_completeness_confirmed:
            return {
                "status": "success",
                "gate_status": "BLOCKED",
                "document_id": request.document_id,
                "confirmed_nodes": confirmed_nodes,
                "human_completeness_confirmed": False,
                "message": "원본 회로도 전체와의 대조 검증(Human Completeness Confirmation) 체크가 필요합니다.",
            }

        return {
            "status": "success",
            "gate_status": "OBJECT_VERIFIED",
            "document_id": request.document_id,
            "confirmed_nodes": confirmed_nodes,
            "unconfirmed_count": 0,
            "human_completeness_confirmed": True,
            "message": "모든 객체 검수 및 도면 완결성 검증이 완료되었습니다. (OBJECT VERIFIED)",
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 🔗 [Review API 5] 확정 객체 기반 결선 검출
# ==========================================
@router.post("/review/detect_connections")
async def review_detect_connections(request: ConnectionReviewRequest):
    print(
        f"\n🔗 [Review: 결선 검출 수신] 문서 ID: {request.document_id}, "
        f"확정 객체 수: {len(request.confirmed_nodes)}"
    )
    try:
        session = session_store.get_session(request.document_id)
        if session is None:
            return {
                "status": "error",
                "message": f"Document session '{request.document_id}' not found or expired",
            }

        result_data = detect_sld_connections_adaptive(
            session.image_bytes, request.confirmed_nodes
        )
        nodes = result_data.get("nodes", request.confirmed_nodes)
        raw_lines = result_data.get("lines", [])
        
        # Propagate verified Bus numbers to connected devices (G_xx, Load_xx)
        nodes = propagate_bus_numbers_to_devices(nodes, raw_lines)

        annotated_lines = extract_all_connections_evidence(nodes, raw_lines)
        annotated_lines = generate_line_display_labels(annotated_lines, nodes=nodes)

        ambiguous_count = sum(
            1 for l in annotated_lines if l.get("review_status") == "AMBIGUOUS"
        )
        detected_count = sum(
            1 for l in annotated_lines if l.get("review_status") == "DETECTED"
        )

        proactive_summary = get_assistant_provider().generate_proactive_summary(
            document_id=request.document_id,
            stage="CONNECTION_REVIEW",
            working_nodes=nodes,
            working_lines=annotated_lines,
        )

        return {
            "status": "success",
            "document_id": request.document_id,
            "review_stage": "CONNECTION_REVIEW",
            "nodes": nodes,
            "lines": annotated_lines,
            "proactive_summary": proactive_summary,
            "connection_summary": {
                "total": len(annotated_lines),
                "ambiguous": ambiguous_count,
                "detected": detected_count,
                "confirmed": 0,
            },
            "pipeline": result_data.get("pipeline", {}),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 🔢 [Review API 5.5] AI 모선 번호 시각적 판독 및 기기 매핑 (Step 3 진입 시)
# ==========================================
@router.post("/review/link_bus_numbers")
async def review_link_bus_numbers(request: LinkBusNumbersRequest):
    print(
        f"\n🔢 [Review: AI 모선 번호 판독 요청] Document: {request.document_id}, "
        f"모선 포함 전체 노드 수: {len(request.working_nodes)}, 선로 수: {len(request.working_lines)}"
    )
    try:
        session = session_store.get_session(request.document_id)
        if session is None:
            return {
                "status": "error",
                "message": f"Document session '{request.document_id}' not found or expired",
            }

        # 1. Run Gemini Set-of-Mark Bus Number Linking on all working nodes (including human-added buses)
        updated_nodes, bus_report = link_and_validate_bus_numbers(session.image_bytes, request.working_nodes)
        
        # 2. Propagate recognized bus numbers to connected generators (G_xx) and loads (Load_xx)
        updated_nodes = propagate_bus_numbers_to_devices(updated_nodes, request.working_lines)

        return {
            "status": "success",
            "document_id": request.document_id,
            "nodes": updated_nodes,
            "bus_number_report": bus_report,
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


@router.post("/review/trace_connection_candidate")
async def review_trace_connection_candidate(
    request: TraceConnectionCandidateRequest,
):
    """Trace one user-selected connection using only source-image pixels.

    This replaces the old editor behaviour that drew a straight line between
    object centres.  The full approved-node topology tracer is reused and a
    candidate is returned only when it already contains the requested pair.
    """
    try:
        session = session_store.get_session(request.document_id)
        if session is None:
            return {
                "status": "error",
                "message": "원본 이미지 세션을 찾을 수 없습니다.",
            }

        source_id = str(request.source_node_id)
        target_id = str(request.target_node_id)
        if source_id == target_id:
            return {
                "status": "error",
                "message": "같은 객체끼리는 선로를 연결할 수 없습니다.",
            }
        known_ids = {
            str(node.get("id")) for node in request.working_nodes
        }
        unknown = [
            node_id
            for node_id in (source_id, target_id)
            if node_id not in known_ids
        ]
        if unknown:
            return {
                "status": "error",
                "message": f"선택 객체를 찾을 수 없습니다: {', '.join(unknown)}",
            }

        result = detect_sld_connections_adaptive(
            session.image_bytes,
            request.working_nodes,
            requested_pair={source_id, target_id},
        )
        wanted_pair = {source_id, target_id}
        candidates = [
            dict(line)
            for line in result.get("lines", [])
            if set(str(item) for item in line.get("connected_to", []))
            == wanted_pair
            and len(line.get("path", [])) >= 2
        ]
        if not candidates:
            return {
                "status": "success",
                "path_found": False,
                "message": "두 객체 사이의 실제 선 픽셀 경로를 찾지 못했습니다.",
            }

        candidate = max(candidates, key=lambda line: len(line.get("path", [])))
        return {
            "status": "success",
            "path_found": True,
            "line": candidate,
            "message": (
                "원본 이미지에서 실제 선 픽셀 경로를 찾았습니다. "
                f"경로 픽셀 수: {len(candidate.get('path', []))}"
            ),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 🤖 [Review API 6] Agent 결선 검수 및 한국어 설명
# ==========================================
@router.post("/review/agent_review_connection")
async def review_agent_connection(request: AgentReviewConnectionRequest):
    print(
        f"\n🤖 [Agent Connection Review 요청] Document: {request.document_id}, "
        f"Line: {request.line.get('line_id')}"
    )
    try:
        session = session_store.get_session(request.document_id)
        img = None
        if session:
            import cv2
            import numpy as np
            img = cv2.imdecode(np.frombuffer(session.image_bytes, np.uint8), cv2.IMREAD_COLOR)

        evidence = extract_connection_evidence(
            request.line, request.nodes, request.lines
        )
        review_res = connection_verifier.review_connection(
            evidence, request.nodes, request.lines, image=img
        )
        return {
            "status": "success",
            "document_id": request.document_id,
            "line_id": request.line.get("line_id"),
            "result": review_res.to_dict(),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 🔍 [Review API 7] 실시간 토폴로지 Graph 검증
# ==========================================
@router.post("/review/validate_topology")
async def review_validate_topology(request: ValidateTopologyRequest):
    try:
        issues = validate_graph(request.nodes, request.lines)
        annotated_lines = extract_all_connections_evidence(request.nodes, request.lines)
        critical_count = sum(1 for i in issues if i.severity == "error")

        return {
            "status": "success",
            "document_id": request.document_id,
            "issues": [i.to_dict() for i in issues],
            "annotated_lines": annotated_lines,
            "critical_issues_count": critical_count,
            "warning_issues_count": len(issues) - critical_count,
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 🏆 [Review API 8] Final Gate 검증 및 VerifiedSLD 발급
# ==========================================
@router.post("/review/verify_final_gate")
async def review_verify_final_gate(request: VerifyFinalGateRequest):
    print(
        f"\n🏆 [Final Gate 검증 요청] Document: {request.document_id}, "
        f"Nodes: {len(request.working_nodes)}, Lines: {len(request.working_lines)}, "
        f"Human Completeness: {request.human_completeness_confirmed}"
    )
    try:
        session = session_store.get_session(request.document_id)
        if session is None:
            return {
                "status": "error",
                "message": f"Document session '{request.document_id}' not found or expired",
            }

        # 1. Check confirmed nodes (clean DETECTED are auto-confirmed)
        confirmed_nodes = []
        suspicious_nodes = []
        for n in request.working_nodes:
            status = str(n.get("review_status", "")).upper()
            if status == "REJECTED":
                continue
            elif status == "SUSPICIOUS":
                suspicious_nodes.append(n)
            else:
                n_copy = dict(n)
                n_copy["review_status"] = "CONFIRMED"
                confirmed_nodes.append(n_copy)

        if len(suspicious_nodes) > 0 or len(confirmed_nodes) == 0:
            return {
                "status": "success",
                "gate_status": "BLOCKED",
                "document_id": request.document_id,
                "message": f"미해결 검토 필요 객체(SUSPICIOUS)가 {len(suspicious_nodes)}개 남아있습니다.",
                "critical_issue_count": len(suspicious_nodes),
            }

        # 2. Check confirmed lines (clean DETECTED are auto-confirmed)
        accepted_lines = []
        ambiguous_lines = []
        for l in request.working_lines:
            status = str(l.get("review_status", "")).upper()
            if status == "REJECTED":
                continue
            elif status == "AMBIGUOUS":
                ambiguous_lines.append(l)
            else:
                l_copy = dict(l)
                l_copy["review_status"] = "CONFIRMED"
                accepted_lines.append(l_copy)

        if len(ambiguous_lines) > 0:
            return {
                "status": "success",
                "gate_status": "BLOCKED",
                "document_id": request.document_id,
                "message": f"미해결 결선 오류 선로(AMBIGUOUS)가 {len(ambiguous_lines)}개 남아있습니다. (승인 또는 제외 필요)",
                "critical_issue_count": len(ambiguous_lines),
            }

        # 3. Synchronize IDs so bus_XX, gen_XX, load_XX match bus numbers 1:1!
        confirmed_nodes, accepted_lines = synchronize_node_and_line_ids(confirmed_nodes, accepted_lines)

        # 4. Deterministic Graph Validation
        issues = validate_graph(confirmed_nodes, accepted_lines)
        critical_issues = [i for i in issues if i.severity == "error"]

        if len(critical_issues) > 0:
            return {
                "status": "success",
                "gate_status": "BLOCKED",
                "document_id": request.document_id,
                "message": f"전기적 무결성 결함(Critical Issue)이 {len(critical_issues)}개 감지되었습니다: {critical_issues[0].message}",
                "critical_issue_count": len(critical_issues),
                "issues": [i.to_dict() for i in issues],
            }

        # 5. Construct VerifiedSLD Document
        verified_nodes = [
            {
                "id": str(n.get("id")),
                "class": str(n.get("class", n.get("class_name", ""))).lower(),
                "bbox": [float(v) for v in n.get("bbox", [0, 0, 10, 10])],
                "confidence": float(n.get("confidence", 1.0)),
                "source": str(n.get("source", "confirmed")),
                "verification_status": "CONFIRMED",
                "display_label": n.get("display_label") or n.get("display_name"),
                "display_name": n.get("display_name") or n.get("display_label"),
                "display_number": n.get("bus_number") or n.get("display_number"),
                "suggested_bus_number": n.get("bus_number") or n.get("suggested_bus_number"),
                "bus_number": n.get("bus_number"),
                "connected_bus_number": n.get("connected_bus_number"),
            }
            for n in confirmed_nodes
        ]

        verified_lines = [
            {
                "line_id": str(l.get("line_id", l.get("id", ""))),
                "connected_to": [str(x) for x in l.get("connected_to", [])],
                "path": l.get("path", []),
                "source_port": str(l.get("source_port", "auto")),
                "target_port": str(l.get("target_port", "auto")),
                "trace_method": str(l.get("trace_method", "electrical_graph")),
                "verification_status": "CONFIRMED",
                "display_label": l.get("display_label"),
                "display_name": l.get("display_name"),
                "endpoints_display": l.get("endpoints_display"),
            }
            for l in accepted_lines
        ]

        verified_sld = {
            "schema_version": "1.0",
            "document_id": request.document_id,
            "status": "VERIFIED",
            "image": {
                "width": session.width,
                "height": session.height,
            },
            "nodes": verified_nodes,
            "lines": verified_lines,
            "verification": {
                "object_gate": "PASS",
                "connection_gate": "PASS",
                "human_completeness_confirmed": bool(request.human_completeness_confirmed),
                "critical_issue_count": 0,
                "total_nodes": len(verified_nodes),
                "total_lines": len(verified_lines),
            },
        }

        return {
            "status": "success",
            "gate_status": "VERIFIED",
            "document_id": request.document_id,
            "verified_sld": verified_sld,
            "message": "회로도 최종 검증이 완료되었습니다. (VERIFIED)",
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 💬 [Review API 9] Context-Aware Agent Chat
# ==========================================
@router.post("/review/agent_chat")
async def review_agent_chat(request: AgentChatRequest):
    print(f"\n💬 [Agent Chat 요청] Document: {request.document_id}, Query: '{request.message}'")
    try:
        from agent.chat_reviewer import ChatMessagePayload
        history_payload = [
            ChatMessagePayload(role=h.get("role", "user"), content=h.get("content", ""))
            for h in request.history
        ]

        result = chat_reviewer.chat(
            message=request.message,
            document_id=request.document_id,
            stage=request.stage,
            selected_node=request.selected_node,
            selected_line=request.selected_line,
            working_nodes=request.working_nodes,
            working_lines=request.working_lines,
            missing_candidates=request.missing_candidates,
            topology_issues=request.topology_issues,
            history=history_payload,
        )

        return {
            "status": "success",
            "document_id": request.document_id,
            "reply_ko": result.get("reply_ko", ""),
            "agent_status": result.get("agent_status", "DETERMINISTIC"),
            "context_summary": result.get("context_summary", {}),
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ==========================================
# 📊 [Review API 10] Proactive Priority Review Summary
# ==========================================
@router.post("/review/proactive_summary")
async def review_proactive_summary(request: ProactiveSummaryRequest):
    try:
        provider = get_assistant_provider()
        res = provider.generate_proactive_summary(
            document_id=request.document_id,
            stage=request.stage,
            working_nodes=request.working_nodes,
            working_lines=request.working_lines,
            missing_candidates=request.missing_candidates,
            topology_issues=request.topology_issues,
        )
        return {
            "status": "success",
            "document_id": request.document_id,
            **res,
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}



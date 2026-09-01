from fastapi import FastAPI, Request, File, UploadFile, Response
from fastapi.middleware.cors import CORSMiddleware
from ultralytics import YOLO
import pandas as pd
import io
import os
from pathlib import Path

try:
    from core.power_logic import construct_y_bus
    from core.pipeline_policy import validate_graph
    from core.adaptive_vision_pipeline import (
        analyze_circuit_image_adaptive,
        detect_sld_objects_adaptive,
        detect_sld_connections_adaptive,
    )
    from review.session_store import session_store
    from review.schemas import (
        ConnectionReviewRequest,
        AgentReviewNodeRequest,
        CheckCompletenessRequest,
        VerifyObjectsGateRequest,
        AgentReviewConnectionRequest,
        ValidateTopologyRequest,
        VerifyFinalGateRequest,
        AgentChatRequest,
        ProactiveSummaryRequest,
    )
    from agent import (
        classify_suspicious,
        extract_object_evidence,
        object_reviewer,
        completeness_reviewer,
        connection_verifier,
        extract_connection_evidence,
        extract_all_connections_evidence,
        chat_reviewer,
        generate_display_labels,
        generate_line_display_labels,
        get_assistant_provider,
    )
except ImportError as e:
    print(f"❌ 에러: 파일을 찾을 수 없습니다. {e}")

app = FastAPI()
yolo_model = None

@app.on_event("startup")
async def startup_event():
    global yolo_model
    print("\n" + "★"*60)
    print(" 🚀 [PowerLens] 통합 서버 가동 시작!")
    try:
        # 2026_07_30_coslr.pt: cos_lr + 런타임 증강 켜서 재학습한 최신 모델.
        # 24bus/IEEE24bus 변압기까지 잡힘(이전 aug모델은 0개). vision_logic imgsz=960과 세트.
        # The local checkpoint remains the safe default.  A friend/all-class
        # checkpoint can be selected for the same hybrid pipeline without
        # changing code: POWERLENS_YOLO_MODEL=<path-to-best.pt>.
        default_model_path = (
            Path(__file__).resolve().parent
            / "models"
            / "2026_07_30_coslr.pt"
        )
        model_path = os.environ.get("POWERLENS_YOLO_MODEL", str(default_model_path))
        yolo_model = YOLO(model_path)
        print(" ✅ AI 모델(YOLO) 로딩 완료!")
    except Exception as e:
        print(f" ❌ 모델 로딩 실패: {e}")
    print("★"*60 + "\n")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
async def health_check():
    return {
        "status": "ok",
        "model_loaded": yolo_model is not None,
    }

# [API 1] 사진 분석 
@app.post("/analyze_image")
async def process_image(file: UploadFile = File(...)):
    print("\n📸 [사진 수신] 분석 요청이 들어왔습니다.")
    try:
        image_bytes = await file.read()
        result_data = analyze_circuit_image_adaptive(image_bytes, yolo_model)
        return {"status": "success", "data": result_data}
    except Exception as e:
        return {"status": "error", "message": str(e)}

# ==========================================
# 🎯 [API 2 - 엑셀 업로드] 플러터에서 엑셀 파일이 날아오면 바로 읽어서 돌려줌!
# ==========================================
@app.post("/upload_excel")
async def upload_excel(file: UploadFile = File(...)):
    print(f"\n📂 [엑셀 수신] 업로드된 파일명: {file.filename}")
    try:
        # 파일을 하드디스크에 저장하지 않고 메모리(BytesIO)에서 바로 엑셀 파싱!
        contents = await file.read()
        
        # 발전기 시트 읽기
        df_gen = pd.read_excel(io.BytesIO(contents), sheet_name='Generator')
        generators = df_gen.set_index('Gen_ID').to_dict(orient='index')
        
        # 선로 시트 읽기
        df_line = pd.read_excel(io.BytesIO(contents), sheet_name='Line')
        lines = df_line.set_index('Line_ID').to_dict(orient='index')
        
        excel_data = {
            "generators": generators,
            "lines": lines
        }
        
        print(f"✅ 엑셀 업로드 및 파싱 성공! 발전기({len(generators)}개), 선로({len(lines)}개) 데이터 전송.")
        return {"status": "success", "data": excel_data}
        
    except Exception as e:
        print(f"❌ 엑셀 처리 중 에러 발생: {e}")
        return {"status": "error", "message": str(e)}

# [API 3] 조류 계산 
@app.post("/run_simulation")
async def run_simulation(request: Request):
    data = await request.json()
    elements = data.get("elements", [])
    print(f"\n⚡ [조류계산 요청] {len(elements)}개의 부품 데이터를 받았습니다.")
    return {"status": "success", "message": "조류 계산 성공!"}


# ==========================================
# 🔍 [Review API 1] 객체 검출 및 Review 세션 생성
# ==========================================
@app.post("/review/detect_objects")
async def review_detect_objects(file: UploadFile = File(...)):
    print(f"\n🔍 [Review: 객체 검출 수신] 파일명: {file.filename}")
    try:
        image_bytes = await file.read()
        content_type = file.content_type or "image/png"
        session = session_store.create_session(image_bytes, content_type=content_type)

        result_data = detect_sld_objects_adaptive(image_bytes, yolo_model)
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
@app.get("/review/image/{document_id}")
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
@app.post("/review/agent_review_node")
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
@app.post("/review/check_completeness")
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
@app.post("/review/verify_objects_gate")
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
@app.post("/review/detect_connections")
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
# 🤖 [Review API 6] Agent 결선 검수 및 한국어 설명
# ==========================================
@app.post("/review/agent_review_connection")
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
@app.post("/review/validate_topology")
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
@app.post("/review/verify_final_gate")
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

        # 3. Deterministic Graph Validation
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

        # 4. Construct VerifiedSLD Document
        verified_nodes = [
            {
                "id": str(n.get("id")),
                "class": str(n.get("class", n.get("class_name", ""))).lower(),
                "bbox": [float(v) for v in n.get("bbox", [0, 0, 10, 10])],
                "confidence": float(n.get("confidence", 1.0)),
                "source": str(n.get("source", "confirmed")),
                "verification_status": "CONFIRMED",
                "display_label": n.get("display_label"),
                "display_number": n.get("display_number"),
                "suggested_bus_number": n.get("suggested_bus_number"),
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
@app.post("/review/agent_chat")
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
@app.post("/review/proactive_summary")
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




# 🏗️ PowerLens 시스템 구성도 (System Architecture)

> **문서 버전**: v2.0.0 (2026-09-27)  
> **문서 목적**: 제17회 전력산업 소프트웨어 경진대회·AI 경진대회 제출용 시스템 구성도 명세  
> **시스템 정의**: 전력 계통 단선도(Single-Line Diagram, SLD) 이미지의 AI/CV 객체 인식, 4단계 Human-in-the-Loop 검수 게이트, 엑셀 제원 연계 검증 및 Full AC Newton-Raphson 조류계산 통합 플랫폼

---

## 1. 시스템 개념 구성도 (Conceptual Flow)

PowerLens는 비전 인식부터 계통 해석에 이르기까지 **데이터 추출 → 엔지니어 검증 → 제원 대조 → 수치해석**의 단계적 파이프라인으로 구성됩니다.

```mermaid
flowchart TD
    subgraph Inputs ["입력 계층 (Input Layer)"]
        SLD["단선도 도면 이미지 (SLD Image)<br/>.png / .jpg / .jpeg"]
        Excel["전력 계통 제원 엑셀 (Excel Case Data)<br/>.xlsx (BUS, BRANCH, GEN, LOAD, TRANS)"]
    end

    subgraph Vision ["비전 인식 계층 (Vision Layer)"]
        ObjDet["객체 검출 (Object Detection)<br/>YOLO11 + 특화 CV 앙상블"]
        BusOCR["모선 번호 인식 (Bus Number Recognition)<br/>Set-of-Mark Crop Grid + Gemini Vision"]
        TopolRecon["토폴로지 복원 (Topology Reconstruction)<br/>심볼 마스킹 + 골격화 + 선로 추적"]
    end

    subgraph Review ["검수 계층 (Review Layer)"]
        P1["Phase 1: 객체 검수 (Object Review)"]
        P2["Phase 2: 모선 매핑 (Bus Mapping Review)"]
        P3["Phase 3: 선로 결선 (Connection Review)"]
        P4["Phase 4: 최종 검증 (Final Validation)"]
    end

    subgraph Agent ["에이전트 / 어시스턴트 계층 (Agent & Assistant Layer)"]
        Lensy["대화형 안내 (Lensy Companion)<br/>UI 가이드 및 선제적 코칭"]
        Evidence["시각적 근거 생성 (Gemini Vision Evidence)"]
        DetGate["결정론적 게이트 (Deterministic Technical Gate)<br/>Supervisor + Local Planner + PatchPreview"]
        Human["인간 승인 권한 (Human Transition Intent)"]
    end

    subgraph Verified ["검증 도면 확정 계층 (Verified SLD)"]
        VSLD["VerifiedSLD 불변 구조체<br/>노드·선로·모선 매핑·방향성 확정"]
    end

    subgraph CrossVal ["엑셀 연계 및 대조 계층 (Excel Binding & Cross Validation)"]
        Binding["Excel Binding & Discrepancy Detection<br/>도면 ↔ 엑셀 설비 교차 검증"]
        Proposal["수리 제안 (Repair Proposal)<br/>엑셀 전용 발전기/부하 대상 (승인 시에만 반영)"]
    end

    subgraph CAD ["도면 편집 계층 (CAD / Canonical Network)"]
        Canvas["인터랙티브 Web CAD 캔버스<br/>심볼 4방향 회전, 1px/10px Nudge, 인스펙터"]
    end

    subgraph Readiness ["해석 준비도 검증 계층 (Power Flow Readiness)"]
        Contract["해석 계약 검증 (Readiness Contract)<br/>슬랙 모선 존재 여부, 임피던스 유효성, 변압기 브랜치 합성"]
    end

    subgraph Solver ["수치해석 계층 (Power Flow Engine)"]
        NR["Full AC Newton-Raphson Solver<br/>Dense NumPy 어드미턴스 행렬(Ybus) 및 야코비안 풀이"]
    end

    subgraph Output ["결과 표출 계층 (Results Layer)"]
        ResCanvas["CAD 선로 유효전력(P) 흐름 방향 벡터 애니메이션"]
        ResTable["모선 전압(V, θ), 발전/부하(P, Q), 계통 손실 표"]
    end

    SLD --> Vision
    ObjDet --> Review
    BusOCR --> Review
    TopolRecon --> Review

    Review <--> Agent
    P1 --> P2 --> P3 --> P4
    P4 --> VSLD

    VSLD --> CrossVal
    Excel --> CrossVal
    Binding --> Proposal
    Proposal --> CAD

    CAD --> Readiness
    Readiness --> Solver
    Solver --> Output
```

---

## 2. 전체 시스템 블록 다이어그램 (Detailed Architecture Diagram)

```mermaid
graph TB
    subgraph Client ["프론트엔드 계층 (Frontend - Flutter Web CAD)"]
        UI_Review["4단계 도면 검수실 (ReviewPage)<br/>• Object Review Bar<br/>• Bus Inspector<br/>• Connection Inspector"]
        UI_Canvas["인터랙티브 CAD 캔버스 (MainCanvas)<br/>• Direct Drag & 1px/10px Nudge<br/>• 4방향 스냅 회전 & Counter-Rotation<br/>• 유효전력 흐름 방향 화살표(➔)"]
        UI_Inspector["전기 파라미터 인스펙터 (InspectorPanel)<br/>• Bus / Branch / Gen / Load 제원 편집<br/>• Missing 파라미터 경고 배지"]
        UI_Mismatch["엑셀 불일치 진단 모달 (ExcelMismatchDialog)<br/>• Repair Proposal 승인/거절 UI"]
        UI_Lensy["Lensy 어시스턴트 패널 (PowerLensAIPanel)<br/>• GlowingTargetWrapper (네온 하이라이트)<br/>• 음성/텍스트 질의응답 브리지"]
    end

    subgraph Gateway ["API 라우팅 계층 (FastAPI - main_server.py)"]
        R_Review["검수 라우터 (/review/*)<br/>• detect_objects, link_bus_numbers<br/>• trace_connections, verify_final_gate"]
        R_Core["핵심 라우터 (/analyze_image, /upload_excel, /apply_excel_to_elements)"]
        R_Agent["에이전트 라우터 (/review/agent_chat, /review/proactive_summary)"]
        R_Solver["해석 라우터 (/run_simulation, /download_result_excel)"]
    end

    subgraph Review_Supervisor ["결정론적 검수 감독 계층 (Deterministic Review Supervisor)"]
        Supervisor["ReviewAgentSupervisor<br/>(상태 전이 제어 & Bounded Retry)"]
        Planner["LocalRulePlanningProvider<br/>(외부 의존 없는 로컬 규칙 플래너)"]
        ToolRegistry["ReviewToolRegistry<br/>• port_aware_retry<br/>• roi_reanalysis"]
        Evaluator["정량 평가기 (_evaluate)<br/>(대상 이슈 감소 및 토폴로지 점수)"]
        PatchGen["PatchPreview 생성기<br/>(Before/After 격리 패치 생성)"]
    end

    subgraph CV_Engine ["컴퓨터 비전 계층 (Vision & Topology Engine)"]
        YOLO["YOLO11 객체 검출기<br/>(2026_07_30_coslr.pt)"]
        CV_Det["특화 기하 검출기<br/>(cv_bus / cv_load / cv_transformer)"]
        SoM["Set-of-Mark 모선 번호 인식기<br/>(bus_number_linker.py)"]
        Skeleton["픽셀 골격화 & 선로 추적기<br/>(adaptive_vision_pipeline.py)"]
        TopolVal["전기 위상 검증기<br/>(electrical_topology.py)"]
    end

    subgraph AI_Assistant ["생성형 AI 어시스턴트 계층 (Gemini Assistant)"]
        Lensy_Core["Lensy 코디네이터 (chat_reviewer.py)"]
        Diag_Agent["엑셀 불일치 분석기 (excel_discrepancy_agent.py)"]
        Gemini_API["Google Gemini API<br/>• Primary: gemini-3.8-flash<br/>• Fallback: gemini-3.6-flash"]
    end

    subgraph Power_Engine ["전력계통 수치해석 계층 (Power Flow Engine)"]
        Excel_Parser["엑셀 케이스 파서 (excel_case_importer.py)<br/>• PSSE / Matpower 표준 양식 정규화"]
        Discrepancy["불일치 판별기 (discrepancy_checker.py)<br/>• Repair Proposal 생성 엔진"]
        Mapper["Verified SLD 매퍼 (verified_sld_canvas_mapper.dart)<br/>• 부하 4방향 회전 스냅 & 토폴로지 전달"]
        Ybus_Builder["어드미턴스 행렬 형성기 (construct_y_bus)<br/>• π-등가회로 서셉턴스(B/2) & 변압기 탭비 모델링"]
        NRSolver["Full AC Newton-Raphson Solver (power_flow_solver.py)<br/>• Dense NumPy 배열 기반 야코비안 풀이"]
    end

    subgraph Storage ["로컬 상태 저장소 (Local Storage Layer)"]
        SessionStore["메모리 세션 스토어 (session_store.py)"]
        ReviewStore["그래프 문서 저장소 (store.py - GraphDocument)"]
    end

    %% 연결 관계
    UI_Review <--> R_Review
    UI_Canvas <--> R_Core
    UI_Canvas <--> R_Solver
    UI_Inspector <--> R_Core
    UI_Mismatch <--> R_Core
    UI_Lensy <--> R_Agent

    R_Review --> Review_Supervisor
    Review_Supervisor --> CV_Engine
    Review_Supervisor --> Storage
    
    R_Core --> CV_Engine
    R_Core --> Power_Engine
    R_Agent --> AI_Assistant
    R_Solver --> Power_Engine

    AI_Assistant -.-> Gemini_API
    SoM -.-> Gemini_API
    CV_Engine --> Storage
    Power_Engine --> Storage
```

---

## 3. 핵심 역할 분담 원칙 (Architectural Role Clarification)

PowerLens는 생성형 AI가 임의로 전력망 데이터를 변경하거나 워크플로를 독단적으로 제어하지 않도록, **4개의 상호 독립된 역할**을 엄격히 규정합니다.

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Gemini / Vision = Evidence Generation (증거 생성)        │
│    • 모선 번호 크롭 판독 및 시각적 OCR 후보 추출             │
│    • 도면-엑셀 제원 간 불일치 원인 자연어 설명 생성          │
│    • 최종 진위 판정 권한 없음 (증거 데이터만 제공)          │
├─────────────────────────────────────────────────────────────┤
│ 2. Lensy = Conversational Assistant & Guidance (대화형 안내) │
│    • 사용자 질의응답 및 다음 검수 단계 추천                 │
│    • 질문 의도에 따른 25개 UI 버튼 네온 점등 (시각적 유도)   │
│    • 독단적인 캔버스 수정 및 단계 강제 전이 불가             │
├─────────────────────────────────────────────────────────────┤
│ 3. Deterministic Gate = Technical Validation (공학적 검증)  │
│    • 토폴로지 고립, 단선, 이상 임피던스, 복회선 규칙 검증    │
│    • 로컬 규칙 플래너 및 패치 프리뷰(PatchPreview) 생성      │
│    • 결함 잔존 시 다음 단계로의 진입 차단 (Gatekeeper)       │
├─────────────────────────────────────────────────────────────┤
│ 4. Human = Review & Explicit Transition Intent (최종 승인)  │
│    • 의심 객체 수동 확인, 모선 번호 최종 검수               │
│    • 수리 제안(Repair Proposal)의 명시적 Apply / Reject     │
│    • 다음 검수 단계 및 조류계산 실행에 대한 배타적 결정권     │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. 데이터 흐름 및 저장 메커니즘 (Data Flow & Storage)

1. **GraphDocument**:
   - `backend_api/review/schemas.py`에 정의된 Pydantic 모델.
   - 단선도 이미지 내 모든 노드(`GraphNode`), 선로(`GraphEdge`), 접속 포트(`Port`), 검출된 결함(`ReviewIssue`)을 불변 식별자(UUID5) 기반으로 버전 관리.
2. **VerifiedSLD**:
   - 4단계 검수 게이트를 통과한 후 확정되는 불변 JSON 스키마.
   - 기하 좌표, 검증된 모선 번호, 장치 결선 정보, 방향성 메타데이터를 포함하여 Web CAD 캔버스로 안전하게 전달.
3. **Canonical Network**:
   - `DrawingElement` 구조체 배열.
   - 캔버스 렌더링, 엑셀 제원 바인딩, 슬랙/PV/PQ 모선 속성 부여, 조류계산 입력 데이터로 사용.
4. **Local In-Memory Persistence**:
   - 외부 클라우드 데이터베이스에 의존하지 않고, 백엔드 프로세스 메모리 기반 `session_store.py` 및 파일 시스템 기반 캐시로 격리 관리.

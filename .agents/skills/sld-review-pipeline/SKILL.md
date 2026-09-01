---
name: sld-review-pipeline
description: >-
  VisionFlow의 Agentic SLD(단선도) 검수 파이프라인 워크플로우. 객체 검출 → Agent 검수 → 사용자 승인 → 객체 확정 Gate → 결선 인식 → 결선 검증 → 사용자 최종 확인 → Verified SLD → Flutter Canvas 전달의 8단계 흐름을 정의.
---

# Agentic SLD Review Pipeline Workflow

이 Skill은 전력계통 단선도 이미지를 받아 객체 인식부터 검수, 결선 추적, 토폴로지 검증을 거쳐 최종 `VERIFIED SLD`로 Flutter 캔버스에 전달하기까지의 표준 실행 절차를 규정한다.

```text
IMAGE
  ↓
OBJECT DETECTION (객체 검출)
  ↓
OBJECT REVIEW (Agent 객체 검수)
  ↓
HUMAN OBJECT REVIEW (사용자 검수)
  ↓
[GATE 1] OBJECT CONFIRMED (객체 확정)
  ↓
CONNECTION DETECTION (결선 인식)
  ↓
CONNECTION REVIEW (Agent 결선 검증)
  ↓
HUMAN CONNECTION REVIEW (사용자 최종 확인)
  ↓
[GATE 2] TOPOLOGY VALIDATION & VERIFIED SLD
  ↓
FLUTTER CANVAS HANDOFF
```

---

## Phase A — Object Detection (1차 객체 검출)

* **도구**: 기존 `analyze_circuit_image` 객체 검출 레이어 ([vision_logic.py:L2579](file:///c:/Users/hpo20/OneDrive/바탕%20화면/Project%20List/전력계통대회2/backend_api/core/vision_logic.py#L2579)).
* **대상 클래스**: `bus`, `generator`, `load`, `transformer`.
* **데이터 보존**: `id`, `class`, `bbox` (`[cx, cy, w, h]`), `confidence`, `source`, 원본 1:1 픽셀 좌표계.
* **원칙**: 이 단계에서는 결선/토폴로지를 최종 확정하지 않고 오직 심볼 후보군만 검출한다.

---

## Phase B — Object Review (Agent 객체 검수)

Agent는 전체 객체를 처음부터 재인식하지 않고, **기존 모델이 불확실하게 판정한 의심 항목**에 집중한다.

### 의심 항목 분류 기준
1. **Low Confidence**: 클래스별 임계값 미만인 후보
2. **Class Conflict / Overlap**: 서로 다른 클래스 간 Bbox 비정상 중첩
3. **Duplicate Detection**: 동일 위치에 중복 검출된 다중 바/심볼
4. **Shape/Geometry Mismatch**: 클래스 형상 규칙 불일치 (예: Bus인데 직선도가 낮거나 끝단이 꺾임)
5. **Suspicious Geometry**: 지나치게 거대한 박스(Monster box) 또는 점 형태의 노이즈

### 활용 도구
* [pipeline_policy.py](file:///c:/Users/hpo20/OneDrive/바탕%20화면/Project%20List/전력계통대회2/backend_api/core/pipeline_policy.py): `CandidatePolicy.decide()` (ACCEPT, RESCUE, REVIEW, REJECT 판정)
* [vision_logic.py](file:///c:/Users/hpo20/OneDrive/바탕%20화면/Project%20List/전력계통대회2/backend_api/core/vision_logic.py): `_refine_generator_circle_for_validation()`, `_looks_like_transformer_pair()`, `_recover_yolo_bus_raster_run()` 등 국소 검증기

---

## Phase C — Human Object Review (사용자 직접 검수)

* **사용자 제공 정보**:
  * 원본 도면 이미지 및 해당 영역 ROI
  * AI가 잡은 Bbox 및 클래스 라벨
  * Confidence 및 Agent가 의심한 사유(Reason)
* **지원 사용자 액션**:
  * `CONFIRM`: 해당 객체 승인
  * `REJECT`: 오검출 객체 삭제
  * `CHANGE_CLASS`: 오분류 클래스 수정 (예: Gen → Trans)
  * `MANUAL_ADD`: 누락된 객체 수동 추가
  * `ADJUST_BBOX`: 위치 및 크기 보정
* **Gate 전환**: 모든 객체가 확인되면 문서 상태를 `OBJECT_REVIEW`에서 `CONNECTION_REVIEW`로 전환한다.

---

## Phase D — Connection Detection (확정 객체 기반 결선 인식)

* **입력**: 사용자와 Agent에 의해 100% 확정된 `CONFIRMED` 노드 목록.
* **실행 절차**:
  1. 전도체 히스테리시스 이진화 및 숫자/텍스트 획 마스킹
  2. 확정된 심볼 Bbox 마스킹 및 관통 전도체 복원
  3. 1픽셀 갭 브릿징 및 스켈레톤화 ([electrical_topology.py:L86](file:///c:/Users/hpo20/OneDrive/바탕%20화면/Project%20List/전력계통대회2/backend_api/core/electrical_topology.py#L86))
  4. 컴포넌트 포트 생성 및 Endpoint-Port 매칭
  5. 교차로(Crossing) 가상 레인 분기 생성
  6. 방향성 Dijkstra 최단경로 결선 추적 ([electrical_topology.py:L713](file:///c:/Users/hpo20/OneDrive/바탕%20화면/Project%20List/전력계통대회2/backend_api/core/electrical_topology.py#L713))

---

## Phase E — Connection Review (Agent 결선 검증)

결선 결과를 임의 확정하지 않고 [pipeline_policy.py:L399](file:///c:/Users/hpo20/OneDrive/바탕%20화면/Project%20List/전력계통대회2/backend_api/core/pipeline_policy.py#L399)의 `validate_graph()`를 실행하여 전기적 위상 결함을 검출한다.

### 자동 검출 결함
* `invalid_terminal_degree`: Load 또는 Generator가 미연결(0개)이거나 2개 이상 연결됨
* `invalid_transformer_degree`: Transformer 포트 수가 1~2개가 아님
* `invalid_device_pair`: Load-Load, Gen-Gen, Load-Gen 간 직결 (Bus 누락)
* `isolated_bus`: 선로가 연결되지 않은 고립 Bus
* `self_loop`: 동일 객체로 돌아오는 순환 선로
* `duplicate_edge`: 동일 객체 쌍 사이의 중복 선로
* `unknown_endpoint`: 존재하지 않는 노드 참조
* `dangling_line`: 객체 포트에 닿지 못한 끊긴 선로
* `ambiguous_connection`: 두 개 이상의 인접 Bus 중 연결 대상이 모호한 경우

---

## Phase F — Human Connection Review (사용자 결선 최종 확인)

* **원칙**: Agent가 연결 대상을 임의로 추측하여 확정하지 않는다.
* **상호작용**:
  * 연결이 모호한 부품(예: Generator G3)과 인접한 두 Bus(예: Bus A, Bus B)가 존재할 경우:
  * 원본 도면 ROI, 관련 객체, 2개의 후보 연결선을 사용자에게 제시하고 선택/지적을 요청한다.
* **사용자 피드백 반영**: 사용자의 연결 수정 지시가 들어오면 실제 포트 위치, 선로 기하 구조, 기존 토폴로지와 대조하여 물리적 타당성을 검증한 후 반영한다.

---

## Phase G — Verified Gate & Verified SLD 생성

다음의 엄격한 3대 조건을 만족해야만 최종 인증된다:

```text
1. Object Issues = 0 (모든 심볼 확정)
2. Critical Connection Issues = 0 (미연결/비정상 결선 해결)
3. Topology Validation = PASS (전기적 그래프 규칙 100% 통과)
```

조건 충족 시 상태를 `VERIFIED`로 변경하고 표준 `VerifiedSLD` JSON 문서를 생성한다.

---

## Phase H — Flutter Canvas Handoff (최종 전달)

* **규칙**: Draft 상태의 결과물은 절대 Flutter 최종 캔버스로 전달하지 않으며, 오직 `VERIFIED SLD`만 전달한다.
* **어댑터 매핑**:
  * Node → `DrawingElement` (CANVAS_CENTER 오프셋 적용, 타입/크기 설정)
  * Line → `DrawingElement(type: Tool.line, aiPath: parsedPath)`
* **결과**: 검증 완료된 단선도가 Flutter [PowerCanvasPage](file:///c:/Users/hpo20/OneDrive/바탕%20화면/Project%20List/전력계통대회2/frontend_app/lib/main.dart#L74)에 오차 없이 정확하게 렌더링된다.

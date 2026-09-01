---
name: visionflow-e2e
description: >-
  VisionFlow 단선도 검증 파이프라인의 현재 구현 상태를 End-to-End로 점검하는 무수정 진단 워크플로우. /visionflow-e2e 호출 시 실행.
---

# VisionFlow End-to-End Inspection Workflow

이 Workflow는 VisionFlow 프로젝트의 전체 파이프라인(환경, 백엔드 헬스, 객체 검출, 객체 검수 계약, 객체 Gate, 결선 인식, 토폴로지 검증, Verified SLD, Flutter 연동 규약)의 현재 상태를 **코드를 수정하지 않고 순수 점검**하여 진단 보고서를 작성하는 실행 절차이다.

> [!IMPORTANT]
> 이 워크플로우는 소스 코드를 자동으로 수정하지 않습니다. 현재 상태를 있는 그대로 진단하고 Blocker와 다음 권장 작업을 명확히 보고합니다.

---

## 실행 절차 (Step-by-Step Execution)

### STEP 1 — Environment Inspection
* Git Root 및 현재 Branch 확인 (`git status`)
* `backend_api/` 및 `frontend_app/` 디렉토리 필수 파일 존재 확인
* 모델 체크포인트 `backend_api/models/2026_07_30_coslr.pt` 존재 및 크기 확인

### STEP 2 — Backend Health Check
* FastAPI `backend_api/main_server.py`의 문법 및 import 무결성 확인
* `GET /health` 엔드포인트 응답 및 YOLO 모델 로딩 가능 여부 확인
* 필요 시 가상환경 패키지(`fastapi`, `ultralytics`, `opencv-python-headless`, `numpy`, `pandas`) 설치 상태 확인

### STEP 3 — Object Detection Inspection
* 기존 테스트 데이터 또는 샘플 도면 이미지가 존재할 경우 객체 검출 추론 실행 점검
* (주의: 샘플 이미지가 없으면 임의 생성하지 않고 `SKIP`으로 표기)
* 출력: `nodes` 리스트 생성 여부 확인

### STEP 4 — Object Review Contract Inspection
* `nodes` 응답 내 각 항목의 필수 필드 검증:
  * `id`: 고유 식별자 (`bus_0`, `load_1` 등)
  * `class`: `bus`, `generator`, `load`, `transformer` 중 하나
  * `bbox`: `[center_x, center_y, width, height]` (4개 원소 float)
  * `confidence`: 0.0 ~ 1.0 범위의 float
  * `source`: `cv_primary`, `yolo_generator`, `yolo_rescue` 등 출처 문자열
  * 좌표계: 원본 이미지 1:1 픽셀 좌표 여부

### STEP 5 — Object Gate Implementation Check
* 현재 시스템에 `OBJECT_REVIEW` → `CONFIRMED` 게이트웨이가 구현되어 있는지 확인:
  * 구현 완료된 경우: 상태 검증 로직 점검
  * 구현 전인 경우: `NOT IMPLEMENTED`로 진단

### STEP 6 — Connection Detection Inspection
* 확정 노드 기반 선로/결선 인식 실행 확인:
  * `lines` 리스트 생성 여부
  * `connected_to`: 유효한 2개의 노드 ID 쌍
  * `path`: 픽셀 좌표 배열
  * `source_port`, `target_port` 메타데이터 포함 여부

### STEP 7 — Graph Validation Check
* `backend_api/core/pipeline_policy.py`의 `validate_graph(nodes, lines)` 실행 경로 점검
* 전기적 무결성 규칙 위반 이슈(미연결 단자, 고립 모선 등) 검출 기능 작동 확인

### STEP 8 — Verified SLD Schema Check
* `status = "VERIFIED"` 조건 및 표준 Verified SLD JSON 생성 로직 점검:
  * 구현 완료 시: `PASS`
  * 구현 전인 경우: `NOT IMPLEMENTED`

### STEP 9 — Flutter Handoff Contract Check
* 생성된 SLD 데이터가 `frontend_app/lib/main.dart`의 `_applyAiDataToCanvas()` 및 `DrawingElement`로 정상 변환되는지 정적/스키마 호환성 검사

### STEP 10 — Regression Test Execution
* [visionflow-regression](../visionflow-regression/SKILL.md) 절차에 따라 3대 단위 테스트 실행 및 결과 수집

---

## STEP 11 — Final Report Output Format

워크플로우 완료 시 반드시 아래 양식을 출력하여 결과를 보고한다:

```text
VISIONFLOW E2E

Object Detection:
PASS / FAIL / NOT IMPLEMENTED

Object Review:
PASS / FAIL / NOT IMPLEMENTED

Object Gate:
PASS / FAIL / NOT IMPLEMENTED

Connection Detection:
PASS / FAIL / NOT IMPLEMENTED

Connection Review:
PASS / FAIL / NOT IMPLEMENTED

Graph Validation:
PASS / FAIL

Verified SLD:
PASS / FAIL / NOT IMPLEMENTED

Flutter Handoff:
PASS / FAIL / NOT IMPLEMENTED

Regression:
PASS / FAIL

Blockers:
1. (핵심 장애 요인 또는 미구현 사항)
2. ...

Next Recommended Step:
(다음에 수행할 구체적 구현 단계)
```

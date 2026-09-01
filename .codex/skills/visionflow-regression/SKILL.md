---
name: visionflow-regression
description: >-
  VisionFlow 기능 추가 및 수정 후 기존 Vision 알고리즘, 토폴로지 스켈레톤, 전기적 무결성 검증, Flutter 연동 계약의 회귀(Regression) 여부를 체계적으로 점검하고 보고하는 테스트 프로토콜.
---

# VisionFlow Regression & Verification Protocol

이 Skill은 Agentic Review 및 검수 기능을 개발하는 과정에서 기존에 안정화된 Vision/Topology 알고리즘과 Flutter 연동 규약이 깨지지 않았는지 검증하기 위한 절차를 정의한다.

---

## 1. 변경 범위 확인 (Impact Scope Analysis)

작업 완료 후 다음 항목을 점검한다:
* 변경된 백엔드 파일 (`backend_api/**`)
* 변경된 프론트엔드 파일 (`frontend_app/**`)
* `vision_logic.py` 또는 `cv_*_experiment.py`의 핵심 객체 검출 수치/임계값 변경 여부
* `electrical_topology.py` 스켈레톤화 및 Dijkstra 결선 추적 로직 변경 여부
* `pipeline_policy.py`의 `validate_graph()` 판정 규칙 변경 여부

---

## 2. 기존 Backend Tests 실행

Python 환경에서 다음 3개의 핵심 단위 테스트를 실행하여 기본 회귀 여부를 검증한다:

```bash
# Workspace root에서 실행
pytest backend_api/tests/test_electrical_topology.py backend_api/tests/test_pipeline_policy.py backend_api/tests/test_symbol_conflict_filters.py -v
```

또는 Python 내장 `unittest` 모듈 사용:

```bash
python -m unittest discover -s backend_api/tests -p "test_*.py" -v
```

### 핵심 테스트 파일
1. `backend_api/tests/test_electrical_topology.py`: 1픽셀 갭 브릿지, Zhang-Suen 스켈레톤 보존, 4방향 교차점 vs T분기 구분, 방향성 최단경로 검증.
2. `backend_api/tests/test_pipeline_policy.py`: 저해상도 스케일링, Bus 꺾임 거부/단편화 구출, 부하 Bus 결선 필수 규칙, Graph Issue 진단.
3. `backend_api/tests/test_symbol_conflict_filters.py`: 화살표 바닥 Bus 오인식 방지, 관통 선로 복원, 변압기 독립 검출, 기하 충돌 필터.

---

## 3. 테스트 실패 시 분류 기준

테스트 실패가 발생하면 추측하지 않고 명확한 증거에 따라 3가지 중 하나로 분류한다:
* `NEW REGRESSION`: 이번 변경으로 인해 기존에 통과하던 테스트가 실패한 경우 (즉시 원인 분석 및 수정 필수).
* `PRE-EXISTING FAILURE`: 이번 작업 전부터 이미 실패하고 있던 기존 이슈 (명확한 이전 실행 로그 또는 히스토리가 있을 때만 분류).
* `ENVIRONMENT FAILURE`: Python 가상환경 패키지 누락(예: `pytest`, `cv2`, `torch`), 경로 문제, 하드웨어 리소스 부족 등 환경적 원인.

---

## 4. 핵심 데이터 계약 (Data Contract) 무결성 검증

### A. Vision Contract
Backend 응답이 최소 다음 구조를 온전히 유지하고 있는지 검사한다:
```json
{
  "status": "success",
  "data": {
    "nodes": [{"id": "...", "class": "...", "bbox": [...], "confidence": 0.0, "source": "..."}],
    "lines": [{"line_id": "...", "connected_to": ["...", "..."], "path": [[x, y], ...]}],
    "pipeline": {"status": "...", "image_profile": {...}, "graph_issues": [...]}
  }
}
```

### B. Topology Contract
* `nodes[].id`: 고유 식별자 보존
* `lines[].connected_to`: 유효한 2개의 노드 ID 배열 `[start_id, end_id]`
* `lines[].path`: 2개 이상의 2차원 정수 픽셀 좌표 리스트 `[[x1, y1], [x2, y2], ...]`
* `lines[].source_port` 및 `target_port`: 문자열 포트 식별자

### C. Flutter Compatibility
* `frontend_app/lib/main.dart`의 `_applyAiDataToCanvas()` 및 `DrawingElement` 파싱 로직과 호환되는지 점검.

---

## 5. 결과 보고 양식 (Report Format)

검증 완료 후 반드시 아래 양식을 준수하여 보고한다:

```text
Regression Check

Backend tests:
PASS / FAIL

Vision contract:
PASS / FAIL

Topology contract:
PASS / FAIL

Flutter compatibility:
PASS / FAIL / NOT TESTED

Regressions found:
- (발견된 회귀 내용 또는 "None")

Tests not executed:
- (실행하지 못한 테스트 항목 및 이유 또는 "None")
```

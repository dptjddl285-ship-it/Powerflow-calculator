# PowerLens 현재 구성 PRD

## 문서 정보

| 항목 | 내용 |
| --- | --- |
| 제품명 | PowerLens |
| 문서 버전 | 0.9 |
| 작성일 | 2026-08-31 |
| 문서 상태 | 현재 구현 정리 및 프로토타입 요구사항 |
| 우선 기능 | 누락 객체 확인 및 복구 |
| 후순위 기능 | 교차점 선로 오류 수정, 실제 조류계산 연동 |

---

## 1. 제품 요약

PowerLens는 전력계통 단선도(Single-Line Diagram, SLD) 이미지를 입력받아
버스, 부하, 발전기, 변압기와 실제 이미지의 선로 픽셀 경로를 추출하고,
이를 편집 가능한 전력계통 모델로 변환하는 시스템이다.

현재 제품의 핵심은 YOLO와 OpenCV 기반의 객체·선로 인식 파이프라인이다.
앞으로는 사용자가 자연어로 분석을 요청하면 기존 Python 분석 도구를
실행하고, 결과를 재검증하여 누락 객체를 찾아주는 대화형 도구 실행 흐름을
추가한다.

핵심 원칙은 다음과 같다.

1. 객체와 선로의 실제 근거는 원본 이미지 픽셀에서 찾는다.
2. LLM은 객체 박스나 선로를 임의로 그리지 않는다.
3. LLM은 검사·재분석·검증 Python 도구를 선택하고 실행한다.
4. 최종 객체 추가는 YOLO/OpenCV 및 전기적 연결 조건을 통과한 경우에만 허용한다.
5. 객체 검출 정답 라벨은 평가에만 사용하고, 실제 추론 과정에는 사용하지 않는다.

---

## 2. 해결하려는 문제

전력계통 단선도는 다음 이유로 자동 모델링이 어렵다.

- 저해상도·JPEG 압축으로 선과 심볼이 끊어진다.
- 버스 번호와 선로가 연결되어 선로 추적이 잘못될 수 있다.
- 부하·발전기·변압기 심볼이 작아 객체 검출에서 누락될 수 있다.
- 선로가 객체 박스 아래로 들어가거나 박스와 겹쳐 보인다.
- 하나의 전도 영역에서 여러 객체와 선로 관계가 동시에 존재한다.
- 교차점에서 실제 접속과 단순 교차를 구분해야 한다.

이번 프로토타입에서는 선로 교차 오류보다 먼저 **검출되지 않은 객체를
찾고 확인하는 기능**을 해결한다. 누락 객체가 그래프에 들어오지 않으면
그 이후의 선로 연결과 조류계산도 신뢰할 수 없기 때문이다.

---

## 3. 목표와 비목표

### 3.1. 목표

목요일 프로토타입은 다음 사용자 흐름을 지원해야 한다.

```text
도면 업로드
  → 기존 YOLO/OpenCV 분석
  → 누락 가능 객체 후보 생성
  → 사용자가 "누락 객체를 찾아줘"라고 요청
  → 후보 이미지 확인
  → 기존 CV 도구로 재검증
  → 누락 객체 후보·근거·결과 이미지 반환
```

구체적인 목표는 다음과 같다.

- 기존 객체·선로 파이프라인을 그대로 사용한다.
- 현재 결과에서 누락 가능성이 높은 위치를 자동으로 추린다.
- 부하 누락을 첫 번째 복구 대상으로 한다.
- 이후 발전기, 변압기, 버스 순서로 확장할 수 있는 구조를 만든다.
- 각 후보에 대해 `confirmed`, `rejected`, `review` 상태를 반환한다.
- 사용자의 자연어 명령과 실행된 도구·결과를 로그로 남긴다.
- LLM이 반환한 추정만으로 객체나 선로를 최종 반영하지 않는다.

### 3.2. 비목표

목요일 프로토타입에서는 다음을 범위에서 제외한다.

- 모든 종류의 누락 객체를 한 번에 100% 복구하는 것
- LLM이 직접 선로 좌표를 생성하는 것
- LLM이 직접 바운딩 박스를 최종 확정하는 것
- 선로 교차점 전체를 완벽하게 자동 수정하는 것
- YOLO 모델을 새로 재훈련하는 것
- 여러 LLM을 사용하는 복잡한 멀티에이전트 구조
- 실제 Newton-Raphson 조류계산 완성
- 장기 메모리, 사용자 계정, 배포 환경 구축

---

## 4. 현재 구현 상태(As-Is)

현재 시스템에는 LLM 기반 대화형 실행 기능이 아직 없다. 현재는 이미지
업로드 후 하나의 분석 흐름을 실행하여 `nodes`와 `lines`를 반환한다.

| 영역 | 현재 사용 도구 | 현재 상태 |
| --- | --- | --- |
| 이미지 API | Python, FastAPI | 구현됨 |
| 객체 AI | Ultralytics YOLO `.pt` 모델 | 구현됨 |
| 객체 보정 | OpenCV, NumPy, 자체 CV 로직 | 구현됨 |
| 부하 검출 | 삼각형·shaft·버스 연결 검사 | 구현됨 |
| 발전기 검출 | YOLO 제안 + 원형/외부 lead 검사 | 구현됨 |
| 변압기 검출 | wave/circle pair 기반 OpenCV 검사 | 구현됨 |
| 버스 검출 | 방향성 bar 검출 및 profile/branch 검사 | 구현됨 |
| 선로 추적 | 이진화, gap bridge, skeleton, 방향성 그래프 | 구현됨 |
| 화질 보정 | 해상도·선 두께·대비·흐림 프로파일링 | 구현됨 |
| 그래프 검사 | 연결 차수, 중복, 자기 루프, 고립 버스 등 | 구현됨 |
| 재시도 계획 | `retry_plan` 문자열 생성 | 계획만 생성됨 |
| 재시도 실행 | 국소 재추적 자동 실행 | 아직 없음 |
| 자연어 명령 | 사용자 질문을 받는 API/UI | 아직 없음 |
| 결과 편집 | Flutter CustomPaint 캔버스 | 구현됨 |
| 엑셀 입력 | pandas, openpyxl | 파싱 구현됨 |
| Y-Bus | NumPy 기반 행렬 구성 함수 | 부분 구현됨 |
| 실제 조류계산 | `/run_simulation` 전체 계산 | 미완성 |

### 4.1. 현재 주요 코드 구조

```text
backend_api/main_server.py
  ├─ POST /analyze_image
  ├─ POST /upload_excel
  └─ POST /run_simulation

backend_api/core/adaptive_vision_pipeline.py
  └─ 이미지 프로파일링 및 분석 결과 좌표 복원

backend_api/core/vision_logic.py
  └─ YOLO + OpenCV 객체 통합 및 전체 분석

backend_api/core/electrical_topology.py
  └─ skeleton 기반 실제 픽셀 선로 추적

backend_api/core/pipeline_policy.py
  └─ 후보 상태·그래프 문제·재시도 계획 생성

frontend_app/lib/main.dart
  └─ 이미지 업로드, nodes/lines 수신, 편집 캔버스 표시
```

### 4.2. 현재 파이프라인 흐름

```text
Flutter 이미지 업로드
  → FastAPI /analyze_image
  → adaptive_vision_pipeline
  → YOLO 및 OpenCV 객체 검출
  → 숫자 제거·객체 마스킹·선로 마스크 생성
  → skeleton 및 포트 기반 선로 추적
  → graph validation/report
  → nodes, lines, pipeline 반환
  → Flutter 캔버스 표시
```

현재 `pipeline_policy.py`는 오류를 발견하고 `retry_plan`을 만들지만,
그 계획을 실제로 실행하여 결과를 비교하는 반복 흐름은 아직 없다.

---

## 5. 목표 구성(To-Be)

### 5.1. 사용자 관점

사용자는 단순히 분석 버튼만 누르는 것이 아니라 다음과 같이 요청할 수 있다.

```text
"누락된 객체를 찾아줘"
"부하가 빠진 곳만 확인해줘"
"이 후보가 실제 발전기인지 검사해줘"
"검증된 누락 객체만 결과에 추가해줘"
```

시스템은 질문에 답변만 하는 것이 아니라, 현재 분석 결과와 이미지 후보를
확인하고 기존 Python 도구를 실행한 뒤 수정 결과를 반환해야 한다.

### 5.2. 목표 아키텍처

```text
Flutter
  ├─ 이미지 업로드
  └─ 자연어 명령 입력
          ↓
FastAPI
  ├─ /analyze_image       기존 1차 분석
  └─ /agent_command       새 대화형 실행 요청
          ↓
판단·검증 workflow
  ├─ 기존 분석 결과 읽기
  ├─ 누락 후보 생성 도구 호출
  ├─ 후보 이미지 확인
  ├─ YOLO/OpenCV 재검증 도구 호출
  ├─ 중복·전기 조건 검사
  └─ 결과 및 실행 로그 반환
          ↓
최종 nodes + lines + missing_candidates + audit_log
```

LLM을 사용하는 경우에는 Python에서 OpenAI 공식 SDK의 Responses API 함수
호출 방식을 사용한다. LLM이 호출할 수 있는 함수는 내부 Python 도구로
제한하며, `draw_new_line`과 같은 임의 생성 도구는 제공하지 않는다.

---

## 6. 누락 객체 확인 workflow

### 6.1. 1차 분석

기존 `analyze_circuit_image_adaptive()`를 그대로 실행한다.

입력:

- 원본 도면 이미지
- YOLO 모델

출력:

- 검출된 `nodes`
- 추적된 `lines`
- `pipeline.image_profile`
- `pipeline.graph_issues`
- 낮은 confidence 또는 탈락 후보에 대한 내부 근거

### 6.2. 누락 후보 생성

다음 신호를 이용해 의심 영역을 만든다.

1. 선로가 객체 없이 끝나는 지점
2. 연결되지 않은 버스
3. 객체 포트가 0개인 발전기·부하 후보
4. 낮은 confidence의 YOLO 후보
5. OpenCV가 검출했지만 최종 탈락시킨 후보
6. 원본 이미지에 남은 원형·삼각형·코일 형태의 연결 성분
7. 기존 노드와 겹치지 않는 심볼 형태의 픽셀 성분

후보 생성 단계는 결정론적 Python 로직으로 먼저 만들고, LLM은 후보를
만드는 것이 아니라 후보의 우선순위와 확인 요청을 보조한다.

### 6.3. 후보 crop 및 의미 확인

각 후보 주변을 적당한 여백과 함께 crop한다.

LLM 또는 이미지 판별 모델에 전달하는 정보:

- 후보 crop 이미지
- 후보 좌표
- 주변에 있는 기존 객체 목록
- 연결 선로의 끝점 정보
- 후보가 생성된 이유

반환 예시:

```json
{
  "is_object_present": true,
  "possible_classes": ["load"],
  "confidence": 0.86,
  "reason": "삼각형 형태와 버스 방향 shaft가 함께 보임"
}
```

### 6.4. CV 최종 검증

LLM 판단은 최종 승인 조건이 아니다. 후보 유형별로 기존 CV 규칙을 다시
실행한다.

| 후보 | 필수 검증 |
| --- | --- |
| 부하 | 삼각형/화살표 core, tail/shaft 방향, 버스 연결 |
| 발전기 | 원형 외곽, 외부 lead, 버스 방향 terminal |
| 변압기 | 두 winding 또는 circle pair, 외부 lead, 포트 방향 |
| 버스 | 직선 bar, 두께 profile, branch, endpoint bend 여부 |

검증 결과가 통과한 경우에만 최종 `nodes`에 추가한다.

### 6.5. 중복 병합 및 결과 반환

후보가 기존 YOLO/CV 객체와 겹치면 새 객체를 만들지 않고 기존 객체의
검증 상태를 갱신한다. 통과한 후보에는 다음 정보를 남긴다.

```json
{
  "class": "load",
  "bbox": [120, 340, 24, 32],
  "status": "confirmed",
  "source": "llm_candidate_cv_validated",
  "evidence": {
    "triangle_score": 0.81,
    "tail_continuity": 0.94,
    "attached_to_bus": true
  }
}
```

---

## 7. 기능 요구사항

### FR-01. 기존 분석 유지

기존 `/analyze_image`는 현재 반환 형식과 선로 경로를 유지해야 한다.
누락 객체 기능의 실패가 기존 객체·선로 분석을 중단시키면 안 된다.

### FR-02. 누락 후보 생성

시스템은 기존 분석 결과와 원본 픽셀 근거를 이용해 누락 후보를 생성해야
한다. 후보는 원본 이미지 좌표계로 반환해야 한다.

### FR-03. 자연어 명령

`/agent_command`는 최소한 다음 명령을 처리해야 한다.

- `누락 객체 찾아줘`
- `누락된 부하를 찾아줘`
- `이 후보를 다시 검사해줘`

### FR-04. 도구 실행 기록

각 요청은 다음 실행 이력을 남겨야 한다.

```json
{
  "audit_log": [
    {"step": "initial_analysis", "status": "completed"},
    {"step": "candidate_generation", "count": 4},
    {"step": "cv_validation", "confirmed": 1, "rejected": 3}
  ]
}
```

### FR-05. 최종 승인 규칙

LLM이 높은 confidence를 반환하더라도 다음 조건을 통과하지 못하면 객체를
자동 추가하지 않는다.

- 기존 객체와 중복되지 않음
- 객체 유형별 CV 필수조건 통과
- 필요한 경우 실제 선로 tail/lead 연결 확인
- 그래프에 추가했을 때 자기 루프·불가능한 장치 연결이 없음

### FR-06. 결과 시각화

결과 이미지는 최소한 다음을 서로 구분해야 한다.

- 기존 확정 객체
- 누락 후보
- CV 검증을 통과한 복구 객체
- 검증 실패 후보

부하는 기존 UI 규칙에 따라 파란색으로 표시한다.

### FR-07. 선로 비생성

누락 객체 기능은 임의의 직선 선로를 만들 수 없다. 새 객체의 연결은
원본 이미지의 실제 픽셀 경로 또는 기존 CV가 검증한 실제 연결 증거로만
생성한다.

---

## 8. 도구 구성

### 8.1. 현재 있는 도구

| 도구 | 구현 위치 | 역할 |
| --- | --- | --- |
| 전체 이미지 분석 | `backend_api/core/adaptive_vision_pipeline.py` | 화질 보정 후 기존 분석 실행 |
| 객체 통합 검출 | `backend_api/core/vision_logic.py` | YOLO와 OpenCV 결과 결합 |
| 선로 추적 | `backend_api/core/electrical_topology.py` | 실제 skeleton 픽셀 경로 탐색 |
| 그래프 검증 | `backend_api/core/pipeline_policy.py` | 연결 차수·중복·불가능 연결 검사 |
| 부하 CV 검증 | `backend_api/cv_load_experiment.py` | 화살표·shaft·버스 연결 검사 |
| Flutter 표시 | `frontend_app/lib/main.dart` | nodes/lines 결과를 캔버스에 표시 |

### 8.2. 새로 만들 도구

| 도구 | 역할 |
| --- | --- |
| `run_initial_analysis` | 기존 전체 분석 호출 |
| `build_missing_candidates` | 고립 끝점·탈락 후보·저신뢰 후보 수집 |
| `inspect_candidate_crop` | 후보 crop의 객체 유형 및 근거 확인 |
| `validate_object_candidate` | YOLO/OpenCV 필수조건 재검증 |
| `merge_validated_object` | 중복 확인 후 확정 노드에 병합 |
| `render_missing_object_overlay` | 후보·확정·탈락 영역 시각화 |
| `write_audit_log` | 실행 단계·근거·결과 저장 |

LLM은 위 도구의 입력과 실행 순서만 선택한다. 픽셀 경로 생성, 임의 박스
생성, 임의 연결 생성 함수는 도구 목록에 포함하지 않는다.

---

## 9. API 요구사항

### 9.1. 기존 API

```text
POST /analyze_image
POST /upload_excel
POST /run_simulation
```

기존 `/analyze_image`의 호환성을 유지한다.

### 9.2. 새 API 초안

```text
POST /agent_command
```

요청 예시:

```json
{
  "command": "누락된 부하를 찾아줘",
  "image_id": "current_upload",
  "analysis": {
    "nodes": [],
    "lines": [],
    "pipeline": {}
  }
}
```

응답 예시:

```json
{
  "status": "success",
  "message": "누락 후보 4개 중 1개를 부하로 확인했습니다.",
  "data": {
    "nodes": [],
    "lines": [],
    "missing_candidates": [],
    "audit_log": [],
    "agent_decision": {
      "command": "missing_object_audit",
      "selected_tools": [
        "build_missing_candidates",
        "inspect_candidate_crop",
        "validate_object_candidate"
      ]
    }
  }
}
```

---

## 10. 정답 데이터 및 평가

### 10.1. 현재 확인된 객체 정답

원격 `master`에는 다음 YOLO 라벨 디렉터리가 있다.

```text
backend_api/icon_recognition/datasets/auto_tune_train_labels/
backend_api/icon_recognition/datasets/auto_tune_test_labels/
```

클래스 매핑은 다음과 같다.

```text
0: bus
1: generator
2: load
3: transformer
```

이 라벨은 객체의 위치·종류를 평가하는 정답이다.

### 10.2. 주의사항

- 현재 `학습 IEEE/` 폴더의 `TEST14.jpg`, `TEST17.jpg` 등에 대응하는
  같은 이름의 `.txt` 파일은 없다.
- 원격 라벨은 `test_image17.txt`, `test_image14.txt`와 같은 이름으로
  저장되어 있다.
- 파일명이 다르므로 이미지 내용이 같은지 먼저 확인해야 한다.
- `test_image17.jpg`가 `TEST17.jpg`와 같은 이미지라고 가정해서는 안 된다.
- 확인된 정답 라벨은 추론 시 사용하지 않고 개발·평가 시에만 사용한다.
- 현재 저장소에는 객체 정답과 별개로, 선로 endpoint pair를 기계적으로
  기록한 연결관계 정답파일이 없다.

### 10.3. 누락 객체 평가 방법

1. 이미지와 라벨 파일의 실제 대응 관계를 확인한다.
2. YOLO 라벨을 원본 픽셀 좌표의 box로 변환한다.
3. 현재 PowerLens 결과와 class별 IoU로 매칭한다.
4. 정답에는 있지만 결과에 없는 box를 `false_negative`로 기록한다.
5. 그 누락 위치가 후보 생성기와 LLM 확인 단계에서 다시 발견되는지 측정한다.

프로토타입 기본 지표는 class별 TP/FP/FN과 IoU 0.5 기준 매칭으로 한다.
최종 자동 추가 기준은 CV 검증 결과와 별도로 관리한다.

---

## 11. 성공 기준

목요일 프로토타입은 다음 조건을 만족하면 완료로 본다.

- 현재 CV 파이프라인 회귀 테스트 45개가 통과한다.
- 기존 `/analyze_image`가 기존 결과 형식으로 동작한다.
- `누락된 객체 찾아줘` 명령이 실제 분석 도구를 호출한다.
- 최소 한 개의 알려진 부하 누락 사례를 후보로 표시한다.
- 후보 이미지와 후보 생성 근거를 확인할 수 있다.
- CV 검증을 통과한 후보와 실패 후보가 구분된다.
- LLM이 임의의 선로 또는 검증되지 않은 객체를 결과에 넣지 못한다.
- 실행 단계와 최종 판단 이유가 JSON 로그에 남는다.
- 정답 라벨을 추론 입력으로 사용하지 않는다.

---

## 12. 목요일까지의 개발 일정

### 8월 31일 월요일: 기준선과 평가 준비

- 현재 파이프라인 결과와 45개 테스트 기준 고정
- 라벨 이미지와 `TEST14`·`TEST17` 파일의 실제 매칭 여부 확인
- 누락 객체 후보 JSON 형식 확정
- 부하 누락 사례 1~3개 선정

### 9월 1일 화요일: 누락 후보 생성

- 고립 선로 끝점·고립 버스·저신뢰 후보 수집
- 부하 후보 crop 생성
- 기존 `cv_load_experiment.py` 검증 로직 연결
- LLM 없이도 후보 목록과 검증 결과가 나오는 상태 완성

### 9월 2일 수요일: 자연어 명령 연결

- `/agent_command` 추가
- LLM 함수 호출 또는 개발용 mock workflow 연결
- `누락된 부하를 찾아줘` 명령 처리
- 후보·확정·실패 overlay를 Flutter에 표시

### 9월 3일 목요일: 시연 안정화

- TEST14, TEST17 및 라벨이 매칭되는 이미지로 시연
- 기존 회귀 테스트 재실행
- 실행 로그와 전후 이미지 저장
- PRD, architecture diagram, workflow 설명 정리
- 프로토타입 브랜치에 최종 커밋

---

## 13. 위험요소와 대응

| 위험 | 대응 |
| --- | --- |
| LLM이 심볼을 잘못 판단 | 후보 crop만 제공하고 CV 필수 검증 수행 |
| LLM이 가짜 box를 반환 | LLM box는 제안으로만 사용하고 OpenCV로 재추출 |
| 저해상도에서 실제 심볼과 숫자 혼동 | 원본 객체 레이어와 숫자 제거 선로 레이어 분리 |
| 누락 후보가 너무 많음 | 우선 부하만 활성화하고 후보 수를 제한 |
| 검증 실패 시 기존 결과 손상 | 기존 결과를 보존하고 후보 상태만 `rejected/review`로 반환 |
| 정답 이미지 파일명 불일치 | 이미지 내용·크기·해시를 기준으로 매칭 |
| 선로가 임의로 늘어남 | 선로 생성 도구를 제공하지 않고 source-pixel 검사 강제 |
| 외부 LLM API 장애 | LLM 없이도 후보 생성·CV 검증이 동작하는 fallback 유지 |

---

## 14. 향후 확장

### 14.1. 객체 확장

```text
부하
 → 발전기
 → 변압기
 → 버스
```

각 객체를 독립적인 후보 생성·검증 모듈로 확장한다.

### 14.2. 선로 오류 수정

누락 객체 기능이 안정화된 후 다음을 추가한다.

- 교차점 급격한 방향 전환 탐지
- 원본 픽셀 일치율 및 직진성 평가
- 국소 직진 유지 재추적
- 기존 경로와 후보 경로 비교
- 연결관계 변경 전 사용자 확인

### 14.3. 전력계통 해석

- 객체·선로 결과와 엑셀 파라미터 매핑
- Y-Bus 구성
- Slack bus와 전기 파라미터 검증
- 실제 조류계산
- 계산 결과를 Flutter 캔버스에 표시

---

## 15. 최종 제품 방향

PowerLens의 Agentic AI 기능은 별도의 대화형 챗봇을 추가하는 데 그치지
않는다. 사용자의 요청을 해석하고, 현재 CV 분석 결과를 점검하고, 필요한
검사·재분석 도구를 순서대로 실행하며, 검증 결과를 반영하는 실행 흐름을
제공하는 것이 목적이다.

이번 프로토타입의 한 문장 정의는 다음과 같다.

> **PowerLens는 기존 YOLO·OpenCV 전력계통 도면 분석 결과를 대화 명령으로
> 재검증하여, 누락된 객체를 실제 이미지 근거와 함께 찾아주는 시스템이다.**

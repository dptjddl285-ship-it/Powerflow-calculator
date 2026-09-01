# VisionFlow Competition Rules

이 문서는 VisionFlow 전력계통 단선도(SLD) 검증 및 디지털화 프로젝트에서 Antigravity와 모든 AI Agent가 준수해야 하는 최우선 작업 규칙이다.

---

## 1. 기존 핵심 자산 및 사용자 변경사항 보호

* **핵심 알고리즘 보존**: 기존 YOLO, OpenCV 기하 알고리즘(`cv_bus_refined_experiment.py`, `cv_load_experiment.py`, `cv_transformer_experiment.py`), `electrical_topology.py`의 핵심 로직을 임의로 재작성하거나 대체하지 않는다.
* **사용자 변경사항 보호**: Agent 작업 시작 전부터 존재하는 사용자의 코드, 주석, 설정을 임의로 덮어쓰거나 revert하지 않는다.
* **불필요한 리팩터링 금지**: 요청되지 않은 대규모 리팩터링, 파일 이동, 이름 변경(rename)을 하지 않는다.
* **모델 체크포인트 보호**: `backend_api/models/2026_07_30_coslr.pt` 등 기존 가중치 및 체크포인트 파일을 삭제하거나 덮어쓰지 않는다.
* **파괴적 Git 명령 금지**: `git reset --hard`, `git clean`, `git restore` 등 기존 변경사항을 영구 삭제할 수 있는 명령은 절대 실행하지 않는다.
* **작업 전후 검증**: 작업 시작 전과 완료 후 반드시 `git status`와 `git diff`를 확인하여 의도한 파일만 변경되었는지 검토한다.

---

## 2. 코드 및 실행 기반 사실 확인 원칙

* **실제 Call Path 기준**: 문서나 가정이 아닌, 현재 실제 import 및 call path(`main_server.py` → `adaptive_vision_pipeline.py` → `vision_logic.py` → `electrical_topology.py`)를 기준으로 작업한다.
* **실제 실행 결과 우선**: 문서에 적혀 있다는 이유만으로 구현되었다고 판단하지 않고, 실제 소스 코드와 실행/테스트 결과를 기반으로 판단한다.
* **검증 없는 완료 보고 금지**: 실제 실행하지 않은 테스트를 수행했다고 보고하지 않으며, 테스트하지 못한 항목은 `PASS`가 아닌 `NOT TESTED`로 명시한다.

---

## 3. 2단계 파이프라인 및 Gatekeeper 원칙

```text
회로도 이미지
↓
[Phase 1] 객체 검출 (Object Detection)
↓
[Phase 2] Agent 객체 검수
↓
[Phase 3] 사용자 직접 검수
↓
[Gate 1] OBJECT VERIFIED (객체 인식 확정)
↓
[Phase 4] 선 / 결선 인식 (Connection Detection)
↓
[Phase 5] Agent 결선 검증
↓
[Phase 6] 사용자 최종 확인
↓
[Gate 2] VERIFIED SLD (회로도 검증 완료)
↓
Flutter Canvas 전달
```

* **단계 분리 원칙**: Object Detection 단계와 Connection Detection 단계는 엄격히 분리하여 유지한다.
* **객체 확정 Gate**: 모든 심볼(Bus, Generator, Load, Transformer)이 `CONFIRMED` 되기 전에는 선/결선 인식을 확정하거나 시작하지 않는다.
* **결선 검수 Gate**: 결선 검수와 Topology Validation이 완료되기 전에는 Flutter Canvas로 최종 전달하지 않는다.
* **오직 Verified SLD만 전달**: 미검증 상태의 Draft Detection 결과는 Flutter 최종 Canvas 모델로 전달하지 않으며, 오직 검증이 완료된 `VERIFIED SLD`만 전달한다.

---

## 4. Agent 판정 및 검증 원칙

* **임의 생성 금지**: Agent가 bbox, topology 경로, connection을 임의로 날조(hallucination)하거나 전기적 구조를 추측하여 임의 연결하지 않는다.
* **Deterministic Evidence 우선**: 전기적/위상학적 검증은 LLM의 임의 추론보다 먼저 기존의 deterministic rule과 evidence를 사용한다.
* **기존 정책 우선 활용**: `CandidatePolicy.decide()` ([pipeline_policy.py](file:///c:/Users/hpo20/OneDrive/바탕%20화면/Project%20List/전력계통대회2/backend_api/core/pipeline_policy.py))와 `validate_graph()`의 전기적 규칙(단자수, 장치쌍, 고립모선 등)을 최우선 활용한다.
* **사용자 질문(Human-in-the-Loop)**: 결선 후보가 모호하거나 AI 확신도가 부족한 경우, Agent가 독단적으로 결정하지 않고 원본 ROI 및 후보 목록과 함께 사용자에게 명확히 질문한다.
* **사용자 수정 재검증**: 사용자가 직접 수정한 결선/객체도 원본 이미지 ROI, 포트 기하, 선로 연속성 evidence와 대조하여 유효성을 재확증한다.
* **UI 출력 규칙**: Agent의 장황한 내부 CoT(Chain of Thought)나 불필요한 디버그 추론을 UI에 노출하지 않으며, **Action, Evidence, Result, Status** 중심으로 간결하고 명확하게 제공한다.

# VisionFlow Codex Agent Guide (AGENTS.md)

이 문서는 VisionFlow 전력계통 단선도(SLD) 검증 및 디지털화 프로젝트에서 Codex 및 Orca Agent가 준수해야 하는 프로젝트 작업 가이드라인이자 최우선 운영 규칙이다.

---

## 1. 프로젝트 개요 및 아키텍처

VisionFlow는 도면 이미지(단선도/SLD)를 입력받아 AI 객체 검출, Agentic 검수, 기하학적 결선 추적, 전기적 위상 검증을 거쳐 확정된 `VERIFIED SLD` 데이터를 Flutter 캔버스에 연동하는 시스템이다.

* **Backend**: FastAPI (`backend_api/main_server.py`)
  * 핵심 파이프라인: `adaptive_vision_pipeline.py`
  * 객체/심볼 검출: `vision_logic.py`, `cv_*_experiment.py`
  * 위상 및 결선 추적: `electrical_topology.py`
  * 검증 및 정책 엔진: `pipeline_policy.py`
  * 모델 가중치: `backend_api/models/2026_07_30_coslr.pt`
* **Frontend**: Flutter Web/App (`frontend_app/`)
  * 캔버스 렌더링 및 인터랙션: `frontend_app/lib/main.dart`

---

## 2. 절대 작업 원칙 (Core Safety Rules)

1. **기존 소스 및 모델 보호**:
   * `backend_api/models/2026_07_30_coslr.pt` 등 가중치 파일 삭제/덮어쓰기 금지.
   * `vision_logic.py`, `electrical_topology.py`의 핵심 검출/추적 알고리즘 임의 재작성 금지.
   * 사용자의 명시적 요청 없이 애플리케이션 소스(`backend_api/**`, `frontend_app/**`, `models/**`, `tests/**`)를 대규모 리팩터링하지 않는다.
2. **사용자 기존 변경사항 보존**:
   * 작업 전 `git status`와 `git diff`를 확인하고 사용자가 작성한 코드를 임의로 revert/덮어쓰지 않는다.
3. **파괴적 명령어 금지**:
   * `git reset --hard`, `git clean -fd`, `git restore` 등 영구 삭제 명령 절대 금지.
4. **실제 Call Path 및 실행 기반 검증**:
   * 문서나 가정이 아닌 실제 실행 경로(`main_server.py` → `adaptive_vision_pipeline.py` → `vision_logic.py` → `electrical_topology.py`)를 기준으로 판단한다.
   * 실제 실행하지 않은 테스트를 `PASS`로 거짓 보고하지 않으며, 미실행 항목은 `NOT TESTED`로 명시한다.

---

## 3. 2단계 파이프라인 및 Gatekeeper 원칙

VisionFlow의 핵심은 객체 검출과 결선 검출을 엄격히 분리하고, 각 단계마다 사용자/Agent 검수를 통과해야만 다음 단계로 진행하는 **Gatekeeper 아키텍처**이다.

```text
회로도 이미지
  ↓
[Phase 1] 객체 검출 (Object Detection)
  ↓
[Phase 2] Agent 객체 검수 (Object Review)
  ↓
[Phase 3] 사용자 직접 검수 (Human Object Review)
  ↓
[Gate 1] OBJECT CONFIRMED (객체 인식 확정)
  ↓
[Phase 4] 선 / 결선 인식 (Connection Detection)
  ↓
[Phase 5] Agent 결선 검증 (Connection Review)
  ↓
[Phase 6] 사용자 최종 확인 (Human Connection Review)
  ↓
[Gate 2] TOPOLOGY VALIDATION & VERIFIED SLD (회로도 검증 완료)
  ↓
[Phase 7] Flutter Canvas 전달 (Handoff)
```

* **단계 분리**: 객체(Bus, Gen, Load, Transformer)가 `CONFIRMED` 되기 전에는 결선 인식을 확정하거나 시작하지 않는다.
* **오직 Verified SLD만 전달**: 미검증 상태의 Draft Detection 결과는 Flutter 최종 Canvas로 전달하지 않으며, 오직 Gate 2를 통과한 `VERIFIED SLD`만 전달한다.

---

## 4. Agent 판정 및 검증 원칙

1. **임의 생성(Hallucination) 금지**: Bbox, 결선 경로, 토폴로지 연결을 임의로 날조하거나 추측하여 연결하지 않는다.
2. **Deterministic Evidence 우선**: LLM의 임의 추론보다 기존의 기하 규칙과 `CandidatePolicy.decide()` (`pipeline_policy.py`), `validate_graph()`의 전기적 규칙을 최우선 적용한다.
3. **Human-in-the-Loop**: 결선 후보가 모호하거나 확신도가 부족한 경우 원본 ROI 및 후보 목록과 함께 사용자에게 질문하여 확인한다.
4. **간결한 UI 출력**: Agent의 장황한 내부 CoT(Chain of Thought)나 디버그 로그를 UI에 노출하지 않고, **Action, Evidence, Result, Status** 중심으로 명확히 제시한다.

---

## 5. Codex Skills 안내

프로젝트 루트의 `.codex/skills/`에 정의된 전용 Skills를 상황에 맞게 호출하여 활용한다:

| Skill | 경로 | 목적 |
|---|---|---|
| `visionflow-safety` | `.codex/skills/visionflow-safety/SKILL.md` | 코드 수정 전/중/후 안전 절차 및 자산 보호 지침 |
| `sld-review-pipeline` | `.codex/skills/sld-review-pipeline/SKILL.md` | 8단계 SLD 검수 파이프라인 표준 워크플로우 |
| `visionflow-regression` | `.codex/skills/visionflow-regression/SKILL.md` | 변경 후 회귀 테스트 및 Data Contract 무결성 검증 |
| `visionflow-e2e` | `.codex/skills/visionflow-e2e/SKILL.md` | 파이프라인 전체 상태 무수정 End-to-End 진단 |

---

## 6. 작업 전후 점검 체크리스트

1. **시작 전**:
   - `git status` 확인 (기존 변경사항 파악)
   - 작업 대상 파일 범위 명확화
2. **구현 중**:
   - 최소 범위 수정 원칙 준수
   - [visionflow-safety](.codex/skills/visionflow-safety/SKILL.md) 지침 준수
3. **완료 후**:
   - `git diff` 확인 (불필요한 디버그 코드 및 의도치 않은 수정 점검)
   - [visionflow-regression](.codex/skills/visionflow-regression/SKILL.md) 절차에 따른 단위 테스트 실행
   - 최종 `git status` 확인 및 투명한 결과 보고

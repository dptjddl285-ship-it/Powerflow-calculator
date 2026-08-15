# 🚀 PowerSimulator 통합 인수인계 문서 (Handoff Guide)

> **Repository**: [my-powersimulator (GitHub)](https://github.com/hpo200222-rgb/my-powersimulator)
> **대상**: 다른 PC 작업자, 후속 개발자, AI 협업 에이전트
> **작성일**: 2026-08-15
> **핵심 기능**: Edge AI 단선도 인식 + Pandapower 정밀 조류계산 + 교과서 스타일 회로도 생성기

---

## 📌 1. 시스템 전체 구조 및 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                 Flutter Frontend App (Dart)                 │
│  - 인터랙티브 캔버스 에디터 (Bus, Line, Gen, Load, Trafo)   │
│  - 도면 사진 업로드 및 엑셀 파라미터 매핑                     │
│  - 조류계산 결과 실시간 오버레이 (전압, 위상각, 조류 흐름)   │
└──────────────────────────────┬──────────────────────────────┘
                               │ HTTP REST API (JSON / Multipart)
┌──────────────────────────────▼──────────────────────────────┐
│                  FastAPI Backend (Python 3.12)              │
│                                                             │
│  [1. Vision Recognition]                                    │
│  - YOLO11 객체 탐지 (Bus, Gen, Load, Trafo)                 │
│  - OpenCV 세선화 & 하이브리드 토폴로지 배선 추적             │
│                                                             │
│  [2. Pandapower Engine] (backend_api/core/pandapower_engine)│
│  - 커스텀 캔버스 요소 ➔ Pandapower Net 자동 변환            │
│  - AC 조류 계산 (Newton-Raphson)                            │
│  - IEEE 4, 14, 30, 39, 57, 118 모선 표준 계통 즉시 해석     │
│  - 전압/선로 부하율 컬러맵 단선도(Heatmap SLD) 자동 렌더링   │
│                                                             │
│  [3. Synthetic Circuit Generator]                           │
│  - 교과서/전기도면 규격 흑백 단선도 자동 생성 (3~14 모선)    │
│  - 다양한 결선(루프, 방사상, 메시) 및 부품 심볼 렌더링       │
└─────────────────────────────────────────────────────────────┘
```

---

## 🛠 2. 신규 구현 모듈 및 파일 가이드

### 1) Pandapower 조류계산 및 시각화 엔진
- **파일 경로**: `backend_api/core/pandapower_engine.py`
- **주요 함수**:
  - `build_net_from_elements(elements)`: Flutter/Vision의 JSON 요소 목록을 `pandapowerNet` 객체로 변환
  - `run_power_flow_simulation(elements=..., case_name=...)`: AC 조류계산 실행 및 전압/조류/손실/부하율 요약 + Base64 단선도 이미지 반환
  - `render_single_line_diagram(net)`: 모선 전압 및 선로 부하율 히트맵이 포함된 고화질 SLD 이미지 생성

### 2) 교과서 스타일 회로도 생성기
- **파일 경로**: `backend_api/synthetic_circuit_generator.py`
- **주요 기능**:
  - `test_image1.jpg`와 같은 흑백 전기도면 규격의 단선도 자동 드로잉
  - 가로/세로 모선 바, 발전기(정현파 심볼), 부하(화살표+복소전력), 변압기(2-Circle), 절곡 배선 지원
  - 생성 예시: `backend_api/generated_circuits/` (`variant_1_ring_5bus.png`, `variant_2_radial_transformer_4bus.png`, `variant_3_meshed_6bus.png`)

### 3) 백엔드 통합 서버
- **파일 경로**: `backend_api/main_server.py`
- **서버 실행**:
  ```powershell
  cd backend_api
  python main_server.py
  # http://127.0.0.1:8000
  ```

---

## 📡 3. REST API 엔드포인트 명세

| Method | Endpoint | Description | Request Payload | Response |
| :--- | :--- | :--- | :--- | :--- |
| **POST** | `/run_simulation` | 커스텀 전력망 조류계산 | `{"elements": [...]}` | 상태, 요약 통계, 모선별 전압, 선로별 조류/부하율, 단선도 Base64 이미지 |
| **GET** | `/ieee_cases` | 지원 IEEE 표준 계통 목록 | None | `{"cases": [{"id": "case14", ...}, ...]}` |
| **POST** | `/run_ieee_case` | IEEE 표준 계통 즉시 계산 | `{"case": "case30"}` | 조류계산 결과 및 히트맵 이미지 |
| **GET** | `/render_ieee_image/{case}` | IEEE 계통 단선도 이미지 스트림 | URL 파라미터 (`case14` 등) | `image/png` 바이너리 |
| **POST** | `/analyze_image` | AI 도면 이미지 분석 | `multipart/form-data` (file) | 인식된 부품 및 결선 JSON |
| **POST** | `/upload_excel` | 엑셀 파라미터 파싱 | `multipart/form-data` (file) | 발전기/선로 상세 데이터 |

---

## 🧪 4. 검증 및 테스트 방법

새로운 PC나 환경에서 전체 모듈의 정상 동작을 1초 만에 검증할 수 있는 통합 테스트 스위트가 포함되어 있습니다:

```powershell
# 1. 가상환경 또는 Python 3.12 환경 확인
python --version  # Python 3.12 권장

# 2. 필수 라이브러리 설치 (최초 1회)
pip install pandapower matplotlib fastapi uvicorn httpx python-multipart pandas networkx opencv-python

# 3. 통합 테스트 실행
cd backend_api
python test_pandapower_integration.py
```

### 테스트 통과 기준
- **Test 1**: 커스텀 3모선 전력망 조류계산 및 수렴 검증
- **Test 2**: IEEE 14/30-Bus 표준 계통 파워플로우 검증
- **Test 3**: FastAPI 4개 핵심 엔드포인트 통합 테스트

---

## 💡 5. 다음 추천 확장 작업 (Next Roadmap)

1. **Flutter 프론트엔드 연동 강화**:
   - `/run_simulation` 호출 시 반환되는 `plot_image_base64`를 결과 모달 팝업으로 사용자에게 표시
   - IEEE 표준 계통 불러오기 버튼 추가 (`/ieee_cases` ➔ `/run_ieee_case`)
2. **합성 도면 기반 AI 학습 자동화**:
   - `synthetic_circuit_generator.py`를 활용해 Bounding Box 라벨(`.txt`)과 도면 이미지를 동시에 대량 생성하여 YOLO 추가 학습에 활용

---

## 🔁 6. 현재 비전 인식 피드백 루프 인수인계

이 절은 2026-08-15 기준 `Powerflow-calculator`의 최신 비전 인식 검증 상태와
다음 작업 순서를 기록한다. 이 문서는 **운영/개발 인수인계용**이며, 새 그림을
학습 데이터로 몰래 편입하거나 정답 좌표를 추론 코드에 하드코딩하지 않는다.

### 6.1 현재 기준 코드와 모델

- 기준 소스 저장소: `https://github.com/dptjddl285-ship-it/Powerflow-calculator`
- 분석기: `backend_api.line_recognition.logic.vision_logic_topology_hybrid`
- 모델: `runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt`
- 주요 로직: YOLO 심볼 검출, 1280 canonical scale-preserving 추론, 원본 좌표 복원,
  숫자/텍스트 veto, CV Bus/Load 보강, port-aware 선 연결, 전기적 형상 검사

이 저장소(`my-powersimulator`)는 제품/서버 통합본이다. 위 최신 인식 로직과
체크포인트가 이 저장소에 없을 수 있으므로, 검증을 재현할 때는 기준 소스
저장소를 먼저 동기화하고 경로를 확인한다.

### 6.2 검증 게이트 (현재 통과 상태)

| 게이트 | 결과 | 세부 |
| :--- | :--- | :--- |
| Native Train | **100.0%** | TP 496, FP 0, FN 0 (Bus 237, Generator 85, Load 142, Transformer 32) |
| Scale Matrix 640×640 | **100.0%** | TP 416, FP 0, FN 0 |
| Scale Matrix 912×900 | **100.0%** | TP 416, FP 0, FN 0 |
| Scale Matrix 1280×720 | **100.0%** | TP 416, FP 0, FN 0 |
| Scale Matrix 1600×900 | **100.0%** | TP 416, FP 0, FN 0 |
| Scale Matrix 900×1400 | **100.0%** | TP 416, FP 0, FN 0 |
| Official Test | **아직 실행하지 않음** | 새 그림 시각 검증 후에만 1회 실행 |

### 6.3 반드시 지킬 실행 순서

1. 기준 소스에서 변경 전 `Train`을 실행한다.
2. Train이 클래스별로 `FP=0, FN=0`인 정확한 100%인지 확인한다.
3. 승인된 크기/해상도 조합 전체가 100%인지 확인한다.
4. 위 두 게이트를 통과한 동일 코드 상태에서만 `new pictures`를 **검토용**으로
   박스친다. 검토용 결과는 학습에 사용하지 않는다.
5. 사용자가 오검출/미검출을 시각적으로 확인해 목록으로 전달한 뒤에만 한 가지
   일반화 가능한 전략을 수정한다.
6. 수정 후에는 다시 1번부터 반복한다. 동일 코드 상태에서 Official Test를
   반복 실행하지 않는다.

### 6.4 재현용 Train 명령 (PowerShell)

```powershell
$env:AUTO_TUNE_MODEL_PATH='runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt'
$env:AUTO_TUNE_USE_PORT_AWARE='1'
$env:AUTO_TUNE_USE_CV_LOAD_PORTS='1'
$env:AUTO_TUNE_USE_SECONDARY_INFERENCE='1'
$env:AUTO_TUNE_USE_CV_BUS_RESCUES='1'
$env:AUTO_TUNE_USE_CANONICAL_RESIZE_INFERENCE='1'
python -m backend_api.validation_tests.auto_tune_evaluator `
  --split train `
  --module backend_api.line_recognition.logic.vision_logic_topology_hybrid `
  --iou 0.4
```

### 6.5 새 그림 시각 검토 산출물

최신 boxed 결과와 원본-검출 좌우 비교본은 독립 검토 경로에 저장한다.

```text
C:\Users\hpo20\orca\workspaces\Powerflow-calculator\antigravity-independent-feedback-loop\new pictures\
└─ comparison\
```

`*_boxed.jpg`와 `comparison/*_comparison.jpg`는 사람이 오류 위치를 확인하기
위한 결과물이다. 원본 이미지 및 라벨은 삭제/덮어쓰기하지 않는다.

### 6.6 역할 분리와 안전 규칙

- Codex 또는 지정된 coordinator만 파일을 수정하고 검증 명령을 실행한다.
- Antigravity는 필요할 때 read-only reviewer로만 사용한다.
- 원본 Train/Test 데이터셋, 체크포인트, 사용자 검토용 원본은 삭제하지 않는다.
- 사용자가 오류 목록을 주기 전에는 Official Test를 실행하거나 새 그림을 학습에
  편입하지 않는다.

---

## ✅ 7. 인수인계 체크리스트

- [ ] `PRD.md`에서 제품 요구사항과 본 문서의 운영 절차를 함께 확인
- [ ] 기준 소스 저장소와 현재 브랜치/모델 경로 확인
- [ ] Native Train 100% 확인
- [ ] 5종 Scale Matrix 100% 확인
- [ ] 새 그림 boxed/comparison 결과를 사람에게 검토받음
- [ ] 검토 결과가 있을 때만 다음 전략을 한 가지 수정

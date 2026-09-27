# 🧪 PowerLens 기술 검증 및 성능 평가 보고서 (EVALUATION)

> **문서 버전**: v2.0.0 (2026-09-27)  
> **관련 제출 트랙**: 제17회 전력산업 소프트웨어 경진대회·AI 경진대회 — 'Agentic AI 활용 문제해결 및 생산성 향상'  
> **평가 대상 코드베이스**: `backend_api/`, `frontend_app/`

---

## 1. 평가 개요 (Evaluation Overview)

PowerLens 플랫폼의 신뢰성과 공학적 타당성을 입증하기 위해 4가지 핵심 영역에서 정량적 검증을 수행했습니다.

1. **컴퓨터 비전 객체 검출 정밀도 (Object Detection Metric)**: 26장의 독립 홀드아웃(Held-out) 단선도 정답셋에 대한 객체 단위 검출 성능.
2. **AC Newton-Raphson 수치해석 솔버 검증 (Power-Flow Solver Validation)**: 24-bus diagram-aligned reference case 및 24-bus PSS/E 포맷 벤치마크 케이스에 대한 반복 수렴성 및 전력 수지 평형 검증.
3. **단위 및 회귀 테스트 스위트 (Automated Regression Test Suite)**: 백엔드 242개 단위/통합 테스트 및 프론트엔드 215개 위젯/로직 테스트 전수 통과.
4. **정적 코드 분석 (Static Analysis)**: Flutter 웹 프론트엔드 분석을 통한 0 errors, 0 warnings 달성.

---

## 2. 컴퓨터 비전 객체 인식 평가 (Section A: Vision Evaluation)

### 1) 객체 검출 지표 (Object Detection Metric)

학습에 사용되지 않은 **26장의 독립 홀드아웃(Held-out) 단선도 정답 데이터셋**을 대상으로 컴포넌트 심볼(모선, 발전기, 부하, 변압기) 인식 성능을 평가했습니다.

- **평가 기준**: Intersection over Union (IoU) $\ge 0.40$
- **사용 모델 가중치**: Ultralytics YOLO11 기반 파인튜닝 체크포인트 (`backend_api/models/2026_07_30_coslr.pt`)
- **평가 지표 요약**:

| 평가 항목 | 수치 | 산출 기준 |
| :--- | :---: | :--- |
| **정밀도 (Precision)** | **98.07%** | $\text{TP} / (\text{TP} + \text{FP}) = 764 / (764 + 15)$ |
| **재현율 (Recall)** | **97.95%** | $\text{TP} / (\text{TP} + \text{FN}) = 764 / (764 + 16)$ |
| **Object Detection F1-Score** | **98.01%** | 정밀도와 재현율의 조화 평균 |
| **True Positive (TP)** | **764건** | 정답 바운딩 박스와 정합 판정된 심볼 수 |
| **False Positive (FP)** | **15건** | 비심볼 영역을 심볼로 오탐지한 건수 |
| **False Negative (FN)** | **16건** | 도면 내 실제 심볼을 미탐지한 건수 |

### 2) ⚠️ 지표 해석 범위 및 한정 (Scope & Disclaimer)

> [!IMPORTANT]
> **본 98.01% F1 지표는 엄격히 "객체 검출(Object Detection F1)" 단계에 한정된 정량 수치입니다.**  
> 전체 단선도의 위상 연결(Topology)이나 전력 계통 E2E 전체가 98% 자동으로 완성된다는 의미가 아닙니다.
> 
> - **토폴로지 복원 메커니즘**: 심볼 객체 검출 이후의 선로 연결은 **포트 인식 기반 픽셀 스켈레톤 추적(Line Tracing)**, **T-분기 및 굴절 경로 분석**, **전기적 위상 무결성 검증 규칙**을 거쳐 형성됩니다.
> - **Human-in-the-Loop 검수 게이트**: 모호 결선(`AMBIGUOUS`), 단선, 미확정 노드는 AI 어시스턴트(Lensy)의 시각적 가이드와 엔지니어의 4단계 검수 게이트(Gate 1~4)를 통해 최종 검증·확정됩니다.

---

## 3. AC Newton-Raphson 조류계산 솔버 수치 검증 (Section B: Solver Validation)

### 1) 수치해석 구현 아키텍처

- **어드미턴스 행렬($Y_{\text{bus}}$) 및 야코비안(Jacobian) 구성**:
  - `backend_api/core/power_flow_solver.py`의 `PowerFlowSolver` 클래스는 **Dense NumPy 2D 배열(`np.zeros((N, N), dtype=complex)`)**과 벡터화 연산을 기반으로 구현되었습니다. (Sparse solver가 아님).
  - 야코비안 선형 연립방정식 $\mathbf{J} \Delta \mathbf{x} = -\mathbf{F}(\mathbf{x})$은 `np.linalg.solve(J, mismatch)`를 통해 고정밀도로 풀이됩니다.
- **수렴 판정 조건**:
  - 활성/무효 전력 최대 불일치 잔차(Mismatch tolerance): $\max(|\Delta P_i|, |\Delta Q_i|) \le 10^{-4}\text{ pu}$
  - 최대 반복 횟수: 25회

### 2) Primary E2E Reference: 24-bus diagram-aligned reference case

- **데이터셋**: `backend_api/sample_cases/case24_ieee_rts_diagram_aligned.xlsx`
- **케이스 성격 및 정의**:
  - 본 케이스는 **"IEEE RTS-24 데이터를 기반으로 제공 단선도(`sample_diagram_ieee24.jpg`)와 정합되도록 구성한 24-bus diagram-aligned reference case"**입니다.
  - **구성 사유**: 공개 IEEE RTS-24 원본 데이터와 실제 제공된 단선도 사이에는 설비 표현(가시 발전기 수, 슬랙 모선, Bus 14 동기조상기 미표시 등)에 차이가 존재합니다. 따라서 `Image → Vision → Bus Number Linking → Topology → Excel Mapping → Transformer Electrical Branch Synthesis → AC Newton-Raphson`에 이르는 전체 파이프라인의 무결성을 공학적으로 올바르게 검증하기 위해, 제공 단선도에 표현된 가시 설비 구성과 정합되도록 구성한 reference case를 사용합니다.
- **도면 정합 기준 설비 구성**:
  - **모선 수 (Buses)**: 24개
  - **가시 발전기 모선 수 (Visible Generator Buses)**: 10개 (Bus 1, 2, 7, 13, 15, 16, 18, 21, 22, 23)
  - **유효 부하 모선 수 (Non-zero Load Buses)**: 17개
  - **변압기 전기적 브랜치 수 (Transformer Electrical Branches)**: 5개 (3-24, 9-11, 9-12, 10-11, 10-12)
  - **기준 슬랙 모선 (Slack Bus)**: **Bus 13** ($V = 1.0200\,\text{pu}, \theta = 0.0^\circ$)
  - **기준 용량 (Base MVA)**: 100 MVA
- **Bus 14 설비 차이 처리 원칙**:
  - 제공 단선도 상에서 Bus 14에는 Generator 또는 Synchronous Condenser 기호가 시각적으로 표시되어 있지 않습니다.
  - PowerLens는 도면에 보이지 않는 발전기를 하드코딩하거나 임의의 동기조상기로 강제 생성하지 않고, 도면과 엑셀 데이터의 물리적 정합성을 정직하게 유지합니다.
- **기준 계산 결과 (Reference Solution)**:

| 검증 항목 | 기준 계산 결과 | 결과 분석 및 판정 기준 |
| :--- | :---: | :--- |
| **수렴 여부 및 반복 횟수** | **4회 반복 수렴** | 허용 오차 $10^{-4}$ 조건 기준 4 iterations에 수렴 달성 |
| **슬랙 모선 발전량 (Bus 13)** | **$P \approx 188.25\,\text{MW}, Q \approx 94.60\,\text{MVAR}$** | 슬랙 모선 수급 평형 정상 수렴 ($188.2517\,\text{MW} / 94.6001\,\text{MVAR}$) |
| **총 부하 유효전력 ($\sum P_d$)** | **2,850.00 MW** | 17개 유효 부하 모선 요구량 충족 |
| **총 계통 유효전력 손실 ($P_{\text{loss}}$)** | **$\approx 52.25\,\text{MW}$** | $\sum P_g (2902.25\,\text{MW}) - \sum P_d (2850.00\,\text{MW}) = 52.25\,\text{MW}$ |
| **대표 모선 전압 및 위상각** | Bus 7: $1.0250\,\text{pu}, -6.95^\circ$<br/>Bus 8: $1.0010\,\text{pu}, -10.78^\circ$<br/>Bus 9: $1.0085\,\text{pu}, -7.33^\circ$<br/>Bus 10: $1.0591\,\text{pu}, -9.42^\circ$<br/>Bus 14: $0.9908\,\text{pu}$ | 전 모선 전압 프로파일 정상 범위 내 산출 |
| **변압기 전기적 브랜치 합성** | **5개 브랜치 복원** | 3-24, 9-11, 9-12, 10-11, 10-12 변압기 탭 방향 및 임피던스 $Y_{\text{bus}}$ 스탬핑 검증 통과 |

### 3) Secondary Solver Benchmark: PSS/E 스타일 레거시 24모선 케이스

- **데이터셋**: `backend_api/sample_cases/case24_psse.xlsx`
- **목적**: PSS/E 포맷 엑셀 파서 및 솔버 단독 회귀 검증용 벤치마크 케이스 (슬랙 모선: #1, 발전기 11기).

| 검증 항목 | 계산 결과 | 판정 기준 및 결과 분석 |
| :--- | :---: | :--- |
| **모선 수 (Buses)** | 24개 | 슬랙 모선: #1 ($V = 1.0\,\text{pu}, \theta = 0.0^\circ$) |
| **유효 브랜치 수 (Branches)** | 34개 | 송전선로 29개 + 탭 변압기 5개 (인입선 분리 완료) |
| **발전기 수 (Generators)** | 11기 | PSS/E 엑셀 정의 기준 |
| **수렴 반복 횟수 (Iterations)** | **4회** | 허용 오차 $10^{-4}$ 조건 기준 4 iterations에 수렴 (최대 잔차: $4.0 \times 10^{-8}$) |
| **총 발전 유효전력 ($\sum P_g$)** | **1,694.655 MW** | 지정된 발전기 유효출력 스케줄 만족 |
| **총 부하 유효전력 ($\sum P_d$)** | **1,672.000 MW** | 24개 모선 총 부하 요구량 충족 |
| **총 계통 손실 ($P_{\text{loss}}$)** | **22.655 MW** | $\sum P_g - \sum P_d = 1694.655 - 1672.000 = 22.655\text{ MW}$ |
| **전력 수지 오차 ($\Delta P_{\text{balance}}$)** | **$0.0\,\text{MW}$** | 발전량 - 부하량 - 손실 = 0.0 MW 전력 수지 확인 |

### 4) ⚠️ 벤치마크 범위 및 면책 조항 (Disclaimers)

> [!NOTE]
> - **PSS/E 및 PowerWorld 직접 비교 관련**: 본 프로젝트에서 "PSS/E 포맷"이란 상용 소프트웨어 PSS/E에서 사용하는 계통 데이터 양식(BUS, BRANCH, GENERATOR, TRANSFORMER 시트)을 파싱하고 호환 입력으로 처리할 수 있음을 의미합니다. **PSS/E 또는 PowerWorld 상용 소프트웨어와의 1:1 직접 비교 검증을 수행한 것은 아닙니다.**
> - **IEEE 명칭 표기**: 공식 원본 IEEE RTS-24 데이터셋이 아닌, 제공 단선도의 가시 설비에 맞추어 구성한 **24-bus diagram-aligned reference case**임을 명시합니다.
> - **수렴 횟수 표기**: 4회 수렴은 본 24모선 기준 케이스에서 허용 오차 $10^{-4}$ 조건으로 계산했을 때 확인된 결과이며, 모든 임의의 계통에서 항상 4회 수렴함을 의미하지 않습니다.

---

## 4. 자동화된 테스트 스위트 검증 결과 (Section C: Automated Test Suite)

PowerLens는 핵심 비즈니스 로직과 전기공학 규칙의 퇴행(Regression)을 방지하기 위해 정기 회귀 테스트 스위트를 전수 가동하고 있습니다.

### 1) 백엔드 테스트 스위트 (`pytest`)

- **실행 명령**: `pytest -q`
- **최종 결과**: **242 passed, 18 subtests passed (100% 통과)**

| 테스트 스위트 파일 | 핵심 검증 내용 | 결과 |
| :--- | :--- | :---: |
| `test_electrical_parameters_and_fallbacks.py` | - 임의의 R/X/B 기본 fallback(`0.01`, `0.05` 등) 전면 배제 확인<br/>- 엑셀 미정의 선로에 대한 사전 시뮬레이션 차단(`MISSING` 상태 반환)<br/>- 무손실 선로($R=0.0, X>0$) 및 $B=0.0$ 정상 수치의 보존 검증<br/>- 직렬 제로 임피던스($R=0, X=0$) 진단 시 $1/Z$ 연산 발산 차단 확인 | **10 passed** |
| `test_generalized_circuits_and_transformers.py` | - 모선 번호 하드코딩 없는 일반화된 복회선(Double Circuit) 병렬 합성<br/>- 변압기 물리 인입선(Lead line) 바이패스 및 2-Port 브랜치 합성 검증<br/>- 변압기 tap ratio 및 tapFromBus 방향 보존 검증 | **7 passed** |
| `test_transformer_topology_resolution.py` | - 서브스테이션 내 다중 변압기 브랜치 매핑 (3-24, 9-11, 9-12, 10-11, 10-12 총 5개 브랜치)<br/>- `electrical_branches` 단위 탭 방향성 및 $Y_{\text{bus}}$ 스탬핑 검증<br/>- 24-bus reference case E2E 회귀 수치해석 검증 (슬랙 모선 #13) | **7 passed** |
| `test_excel_case_importer.py` | - PSSE / Matpower 표준 엑셀 시트 파싱 및 단위 정규화<br/>- 다중 스키마 Sbase 파싱(100, 50, 200 MVA, Key-Value 행, 기본값 폴백)<br/>- 슬랙 모선 자동 탐색 및 다중 스키마 제원 주입 검증 | **9 passed** |
| `test_power_flow_solver.py` | - 3-Bus 및 24모선 계통에 대한 AC Newton-Raphson 수렴 검증<br/>- 모선 전압 크기/위상각 및 전력 수지 평형 확인 | **10 passed** |
| `test_excel_discrepancy_checker.py` | - 도면 설비 vs 엑셀 설비 간 누락/초과 설비 분리 판별<br/>- 2-Port 변압기 및 계통 브랜치 연결 대조, 부하/발전기 독립성 검증 | **4 passed** |
| `test_excel_generator_auto_supplement.py` | - 모선 검증 게이트키퍼 선행 및 모선 불일치 시 수리 제안 차단(ERROR)<br/>- 도면 미검출 발전기/부하에 대한 수리 제안(Repair Proposal) 생성 검증<br/>- 사용자의 명시적 승인(Apply) 시에만 설비 추가, 거절(Reject) 시 도면/솔버 100% 불변 검증<br/>- 모선, 선로, 변압기는 절대로 자동 생성하지 않음을 검증<br/>- 승인된 인입선의 전기적 브랜치($Y_{\text{bus}}$) 배제 및 선로 개수 불변성 검증 | **10 passed** |
| `test_review_api.py` 및 추가 통합 스위트 | - 4단계 검수 세션 생성, 상태 전이, 게이트 판정, 어시스턴트 API 전체 검증 | **185 passed** |

### 2) 프론트엔드 테스트 스위트 (`flutter test`)

- **실행 명령**: `flutter test`
- **최종 결과**: **215 passed (100% 통과, 20개 테스트 파일)**
- **주요 검증 항목**:
  - `verified_sld_canvas_mapper_test.dart`: 수평/수직 모선에 대한 부하 상·하·좌·우 4방향 회전, 인출선 벡터 스냅, 메타데이터 보존 전수 검증.
  - `glowing_highlight_and_arrow_keys_test.dart`: 네온 하이라이트 애니메이션 및 1px/10px 키보드 방향키 이동 동작 검증.
  - `power_flow_v2_test.dart`: CAD 전력조류 애니메이션(유효전력 흐름 방향 화살표) 렌더링 검증.
  - `object_review_v2_test.dart`, `bus_mapping_v2_test.dart`, `connection_review_v2_test.dart`: 4단계 검수 UX 및 Human-in-the-Loop 상호작용 검증.

### 3) 정적 분석 결과 (`flutter analyze`)

- **실행 명령**: `flutter analyze`
- **최종 결과**: **0 errors, 0 warnings** (116 style info)
- 컴파일 차단성 결함 또는 런타임 위험 요소가 존재하지 않음을 확인.

---

## 5. 결론

PowerLens는 단일 AI 모델의 일회성 추론 결과에 의존하지 않고, **검증된 객체 인식 모델(Object Detection F1 98.01%)**, **규칙 기반 전기 위상 검증기**, **Human-in-the-Loop 4단계 검수 게이트**, 그리고 **엄밀한 수학적 AC Newton-Raphson 솔버**를 결합하여 전력 계통 실무에서 신뢰할 수 있는 단선도 디지털화 및 조류계산 환경을 검증하였습니다.

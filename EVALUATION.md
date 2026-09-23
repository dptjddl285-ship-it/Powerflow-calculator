# 🧪 PowerLens 기술 검증 및 성능 평가 보고서 (EVALUATION)

> **문서 버전**: v1.0.0 (2026-09-22)  
> **관련 대회 트랙**: 제17회 전력산업 소프트웨어 경진대회·AI 경진대회 — 'Agentic AI 활용 문제해결 및 생산성 향상'  
> **기준 코드베이스**: `backend_api/core/`, `backend_api/models/`, `backend_api/tests/`

---

## 1. 평가 개요 (Evaluation Overview)

PowerLens 플랫폼의 신뢰성과 공학적 무결성을 입증하기 위해 크게 3가지 영역에서 정량적/정성적 검증을 수행했습니다.

1. **컴퓨터 비전 객체 검출 정밀도 (CV Object Detection Metric)**: 26장의 독립 홀드아웃(Held-Out) 단선도 정답셋에 대한 객체 단위 검출 성능.
2. **AC Newton-Raphson 수치해석 솔버 무결성 (Power-Flow Solver Validation)**: IEEE 24-bus RTS 표준 계통 및 3-Bus 계통에 대한 반복 수렴성 및 전력 수지($\Delta P, \Delta Q$) 균형 검증.
3. **공학 규칙 및 회귀 테스트 스위트 (Automated Regression Test Suite)**: 전기 파라미터 무결성(No-Fallback), 일반화된 복회선 및 변압기 토폴로지 합성 검증.

---

## 2. 컴퓨터 비전 객체 인식 평가 (Section A: Vision Evaluation)

### 1) 객체 검출 지표 (Object Detection Metric)
학습에 사용되지 않은 **26장의 독립 홀드아웃(Held-out) 단선도 정답 데이터셋**을 대상으로 컴포넌트 심볼(모선, 발전기, 부하, 변압기) 인식 성능을 평가했습니다.

- **평가 기준**: Intersection over Union (IoU) $\ge 0.40$
- **사용 모델 가중치**: Ultralytics YOLO11 기반 파인튜닝 체크포인트 (`backend_api/models/2026_07_30_coslr.pt`)
- **평가 지표 요약**:

| 평가 항목 | 수치 | 세부 내역 |
| :--- | :---: | :--- |
| **정밀도 (Precision)** | **98.07%** | $\text{TP} / (\text{TP} + \text{FP}) = 764 / (764 + 15)$ |
| **재현율 (Recall)** | **97.95%** | $\text{TP} / (\text{TP} + \text{FN}) = 764 / (764 + 16)$ |
| **F1-Score** | **98.01%** | 정밀도와 재현율의 조화 평균 |
| **True Positive (TP)** | **764건** | 정답 바운딩 박스와 매칭 성공한 심볼 수 |
| **False Positive (FP)** | **15건** | 비심볼 영역을 심볼로 오탐지한 건수 |
| **False Negative (FN)** | **16건** | 도면 내 실제 심볼을 미탐지한 건수 |

### 2) ⚠️ 지표 해석 범위 및 한정 (Scope & Disclaimer)
> [!IMPORTANT]
> **본 98.01% F1 지표는 "심볼 객체 검출(Object Detection/Recognition)" 단계에 한정된 수치입니다.**  
> 전체 단선도의 '선로 연결 관계(Topology) 및 전기적 결선'이 98% 자동으로 완성된다는 의미가 아닙니다.
> 
> - **토폴로지 복원 메커니즘**: 심볼 객체 검출 이후의 선로 연결은 **포트 인식 기반 픽셀 스켈레톤 추적(Line Tracing)**, **T-분기 및 굴절 경로 분석**, **전기적 위상 무결성 검증 규칙**을 거쳐 형성됩니다.
> - **인간 검수 게이트(Human Review Gate)**: 모호 결선(`AMBIGUOUS`), 단선, 미확정 노드는 에이전트의 패치 프리뷰 및 엔지니어의 4단계 검수 게이트(Gate 1~4)를 통해 최종 검증·확정됩니다.

### 3) 모델 체크포인트 선정 근거
프로젝트 연구 과정에서 동일 아키텍처의 다중 체크포인트를 비교 검증했습니다.  
코사인 어닐링 학습 스케줄러(Cosine Annealing LR)가 적용된 `2026_07_30_coslr.pt` 체크포인트는 고해상도 도면의 미세 선로 기호 노이즈에 대한 안정성과 낮은 FP(오탐 15건)를 보여 최종 기본 모델로 채택되었습니다.

---

## 3. AC Newton-Raphson 조류계산 솔버 수치 검증 (Section B: Solver Validation)

### 1) 수치해석 구현 아키텍처
- **어드미턴스 행렬($Y_{\text{bus}}$) 및 야코비안(Jacobian) 구성**:
  - `backend_api/core/power_flow_solver.py`의 `PowerFlowSolver` 클래스는 고성능 **NumPy 2D 밀집 배열(Dense NumPy Arrays, `np.zeros((N, N), dtype=complex)`)**과 벡터화 연산을 사용하여 구축되었습니다.
  - 야코비안 선형 연립방정식 $\mathbf{J} \Delta \mathbf{x} = -\mathbf{F}(\mathbf{x})$은 `np.linalg.solve(J, mismatch)`를 통해 고정밀도로 풀이됩니다.
- **수렴 판정 조건**:
  - 활성/무효 전력 최대 불일치 잔차(Mismatch tolerance): $\max(|\Delta P_i|, |\Delta Q_i|) \le 10^{-4}\text{ pu}$
  - 최대 반복 횟수: 25회

### 2) IEEE 24-bus RTS 표준 계통 수렴 검증 결과
입력 데이터는 IEEE 24-bus RTS 표준 계통 파라미터(`case24_psse.xlsx` 형식)를 사용하였습니다.

| 검증 항목 | 계산 결과 | 판정 기준 및 결과 분석 |
| :--- | :---: | :--- |
| **모선 수 (Buses)** | 24개 | 슬랙 모선: #1 ($V = 1.0\,\text{pu}, \theta = 0.0^\circ$) |
| **유효 브랜치 수 (Branches)** | 34개 | 송전선로 29개 + 탭 변압기 5개 (인입선 분리 완료) |
| **발전기 수 (Generators)** | 11기 | 동기조상기(SC) 1기(Bus 14) 포함 |
| **수렴 반복 횟수 (Iterations)** | **4회** | 허용 오차 $10^{-4}$ 기준 4회 만에 고속 수렴 |
| **최대 수렴 잔차 (Max Mismatch)** | **$4.0 \times 10^{-8}\,\text{pu}$** | 기준치($10^{-4}$) 대비 4자리 이상 정밀 수렴 |
| **총 발전 유효전력 ($\sum P_g$)** | **1,694.655 MW** | 지정된 발전기 유효출력 스케줄 만족 |
| **총 부하 유효전력 ($\sum P_d$)** | **1,672.000 MW** | 24개 모선 총 부하 요구량 충족 |
| **총 계통 손실 ($P_{\text{loss}}$)** | **22.655 MW** | $\sum P_g - \sum P_d = 1694.655 - 1672.000 = 22.655\text{ MW}$ |
| **전력 수지 오차 ($\Delta P_{\text{balance}}$)** | **$0.0\,\text{MW}$** | 발전량 - 부하량 - 손실 = 0.0 MW 전력수지 완벽 일치 |

### 3) ⚠️ 벤치마크 범위 및 PSS/E 표기 명확화 (Disclaimer)
> [!NOTE]
> - 본 프로젝트에서 "PSS/E 호환"이란 상용 소프트웨어 PSS/E에서 사용하는 계통 데이터 포맷(BUS, BRANCH, GENERATOR, TRANSFORMER 시트) 및 IEEE RTS-24 표준 데이터를 파싱하고 호환 입력으로 처리할 수 있음을 의미합니다.
> - **PSS/E 바이너리 프로그램이나 PowerWorld 엔진과의 1:1 직접 실시간 비교 벤치마크를 수행한 것은 아닙니다.**
> - 수치 검증은 자체 개발한 Full AC Newton-Raphson 솔버의 수렴성, 오차 허용치($10^{-4}$ pu) 달성, 그리고 물리적 전력 수지($\sum P_g = \sum P_d + P_{\text{loss}}$)의 무결성을 수학적으로 입증한 것입니다.

### 4) 도면 인식 기반 조류계산 시 수치 특성 및 하드코딩 배제 원칙
> [!IMPORTANT]
> - **하드코딩 배제 및 공학적 사실주의 원칙**: PowerLens 솔버는 과거 버전과 달리 특정 계통 번호 하드코딩, 도면에 없는 설비(Bus 14 발전기 등)의 임의 자동 주입, 또는 특정 복회선 임피던스를 임의로 축소하는 휴리스틱을 일절 포함하지 않습니다.
> - **도면 기반 인식 시의 수치 특성**: 단선도 이미지에 물리적으로 그려지지 않은 설비 상태로 계산할 경우, 솔버가 가짜 설비를 몰래 생성하지 않으므로 부족한 발전량을 슬랙 모선이 대신 송전하여 선로 손실이 정직하게 산출됩니다.
> - **에이전트 검수 게이트의 역할**: 도면-엑셀 간 설비 불일치는 솔버가 왜곡 보정하는 것이 아니라, 에이전트 검수 게이트(Gate 1~4) 및 수리 제안(Repair Proposal)을 통해 엔지니어가 투명하게 확인하고 보정합니다.

### 5) 테스트 케이스 구분 및 솔버 한계 사항 (Scope & Limitations)
- **두 가지 IEEE-24 케이스 파일의 목적 분리**:
  - `case24_psse.xlsx`: IEEE RTS-24 표준 계통 벤치마크 (슬랙 모선: #1, 발전기 11기). 수치해석 솔버의 고속 수렴 및 전력수지 보존 검증용.
  - `case24_ieee_rts_diagram_aligned.xlsx`: 실제 제공된 단선도 도면(`sample_diagram_ieee24.jpg`)에 시각적으로 표기된 설비(슬랙 모선: #13, 가시 발전기 10기, 부하 17개, 변압기 5기)와 1:1 정렬된 도면 검증용 케이스.
- **솔버 엔지니어링 한계 (Current Limitations)**:
  - 현재 솔버는 Dense NumPy 기반 AC Newton-Raphson 알고리즘을 사용하며, 발전기 무효전력 상하한($Q_{\min}, Q_{\max}$) 초과에 따른 PV $\rightarrow$ PQ 모선 전환(Bus Type Switching) 및 탭 절환에 따른 동적 감도 제어는 미포함 상태입니다.

---

## 4. 자동화된 단위 및 회귀 테스트 스위트 (Section C: Automated Test Suite)

PowerLens는 핵심 비즈니스 로직과 전기공학 규칙의 퇴행(Regression)을 방지하기 위해 상시 회귀 테스트 스위트를 유지하고 있습니다.

```bash
# 회귀 테스트 실행 명령
python -m unittest backend_api/tests/test_electrical_parameters_and_fallbacks.py
python -m unittest backend_api/tests/test_generalized_circuits_and_transformers.py
python -m unittest backend_api/tests/test_excel_case_importer.py
python -m unittest backend_api/tests/test_transformer_topology_resolution.py
python -m unittest backend_api/tests/test_excel_generator_auto_supplement.py
python backend_api/tests/test_power_flow_solver.py
```

### 1) 주요 테스트 항목 및 검증 내용

| 테스트 스위트 파일 | 핵심 검증 내용 | 통과 여부 |
| :--- | :--- | :---: |
| [`test_electrical_parameters_and_fallbacks.py`](backend_api/tests/test_electrical_parameters_and_fallbacks.py) | - 임의의 R/X/B 기본 fallback(`0.01`, `0.05`, `1.0` 등) 전면 제거 확인<br/>- 엑셀 미정의 선로에 대한 사전 시뮬레이션 차단(`MISSING` 상태 반환)<br/>- 무손실 선로($R=0.0, X>0$) 및 $B=0.0$ 정상 수치의 보존 검증<br/>- 직렬 제로 임피던스($R=0, X=0$) 진단 시 $1/Z$ 연산 발산 차단 확인 | **Pass (10/10)** |
| [`test_generalized_circuits_and_transformers.py`](backend_api/tests/test_generalized_circuits_and_transformers.py) | - 모선 번호 하드코딩 없는 일반화된 복회선(Double Circuit) 병렬 합성<br/>- 변압기 물리 인입선(Lead line) 바이패스 및 2-Port 브랜치 합성 검증<br/>- 변압기 tap ratio 및 tapFromBus 방향 보존 검증 | **Pass (7/7)** |
| [`test_transformer_topology_resolution.py`](backend_api/tests/test_transformer_topology_resolution.py) | - 서브스테이션 내 다중 변압기 브랜치 매핑 (3-24, 9-11, 9-12, 10-11, 10-12 총 5개 브랜치)<br/>- `electrical_branches` 단위 탭 방향성 및 $Y_{\text{bus}}$ 스탬핑 검증 | **Pass (7/7)** |
| [`test_excel_case_importer.py`](backend_api/tests/test_excel_case_importer.py) | - PSSE / Matpower 표준 엑셀 시트 파싱 및 단위 정규화<br/>- 다중 스키마 `Sbase` 파싱(100, 50, 200 MVA, Key-Value 행, 기본값 폴백)<br/>- 슬랙 모선 자동 탐색 및 다중 스키마 제원 주입 검증 | **Pass (9/9)** |
| [`test_power_flow_solver.py`](backend_api/tests/test_power_flow_solver.py) | - 3-Bus 및 IEEE 24-bus RTS 계통에 대한 AC Newton-Raphson 수렴 검증<br/>- 모선 전압 크기/위상각 및 전력 수지 무결성 확인 | **Pass (10/10)** |
| [`test_excel_discrepancy_checker.py`](backend_api/tests/test_excel_discrepancy_checker.py) | - 도면 설비 vs 엑셀 설비 간 누락/초과 설비 분리 판별<br/>- 2-Port 변압기 및 계통 브랜치 연결 대조, 부하/발전기 독립성 검증 | **Pass (4/4)** |
| [`test_excel_generator_auto_supplement.py`](backend_api/tests/test_excel_generator_auto_supplement.py) | - 모선 검증 게이트키퍼(Bus Validation Gatekeeper) 선행 및 모선 불일치 시 수리 제안 차단(ERROR)<br/>- 도면 미검출 발전기/부하에 대한 임의 자동 주입 배제 및 수리 제안(Repair Proposal) 생성 검증<br/>- 사용자의 명시적 승인(Apply) 시에만 설비 및 인입선 추가, 거절(Reject) 시 도면/솔버 100% 불변 검증<br/>- 모선, 선로, 변압기는 절대로 자동 생성하지 않는 무결성 검증<br/>- 승인된 인입선의 전기적 브랜치($Y_{\text{bus}}$) 배제 및 선로 개수 불변성 검증 | **Pass (10/10)** |

---

## 5. 결론 및 신뢰성 요약

PowerLens는 단일 딥러닝 모델의 출력에만 의존하지 않고, **검증된 객체 인식 모델(F1 98.01%)**, **규칙 기반 전기 위상 검증기**, **Human-in-the-Loop 4단계 검수 게이트**, 그리고 **엄밀한 수학적 AC Newton-Raphson 솔버**를 유기적으로 결합하여, 실제 전력 엔지니어링 실무에서 신뢰할 수 있는 단선도 디지털화 및 조류계산 환경을 구현하였습니다.

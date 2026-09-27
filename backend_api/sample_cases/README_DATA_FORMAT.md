# 📊 전력계통 데이터 엑셀 입출력 규격 (Power Flow Data Format)

PowerLens는 표준 전력계통 해석용 엑셀 파일(.xlsx)의 입력과 계산 결과 출력을 지원합니다.

---

## 1. 📥 입력 엑셀 규격 (Input Format)

엑셀 파일 하나에 아래 시트들을 구성하여 업로드하면 캔버스 부품 및 도면 검수와 자동 매칭됩니다.

### ① bus 시트 (모선 데이터 - 필수)
모선의 번호, 종류 및 부하량을 정의합니다.
* **Bus**: 모선 번호 (정수, 1, 2, 3...)
* **Type**: 모선 종류 (Swing 또는 Slack, PV, PQ)
* **Pload (MW)**: 해당 모선의 유효전력 부하 (MW)
* **Qload (MVAR)**: 해당 모선의 무효전력 부하 (MVAR)
* **Vm (pu)**: 기준/목표 전압 크기 (기본값: 1.0 pu)
* **Va (degree)**: 기준 위상각 (슬랙 모선: 0.0°)
* **maxVm**, **minVm**: 허용 전압 상한/하한 (기본값: 1.05 / 0.95)

### ② generator 시트 (발전기 데이터)
모선에 연결된 발전기의 발전 출력과 목표 제어 전압을 정의합니다.
* **Bus**: 발전기가 연결된 모선 번호
* **PG (MW)**: 발전기 유효전력 출력 (MW, 동기조상기는 0.0)
* **QG (MVAR)**: 무효전력 초기값 (조류계산 시 자동 산출)
* **Voltage setpoint (pu)**: 발전기 목표 제어 전압 (예: 1.035 pu)
* **MBASE (MW)**: 발전기 용량 베이스 (통상 100 MVA)
* **STATUS**: 운전 여부 (1: 투입, 0: 정지)

### ③ branch 시트 (송전선로 임피던스 데이터 - 필수)
모선 간을 연결하는 송전선로의 물리적 $\pi$-등가회로 파라미터를 정의합니다.
* **From**: 시작 모선 번호
* **To**: 끝 모선 번호
* **R (pu)**: 선로 직렬 저항 (pu)
* **X (pu)**: 선로 직렬 리액턴스 (pu)
* **B (pu)**: 선로 충전 서셉턴스 (pu, 없으면 0.0)

### ④ transformer 시트 (변압기 탭비 데이터 - 선택)
변압기가 설치된 선로의 오프노미널 권선비(Tap)를 정의합니다.
* **From**: 1차측(탭 측) 모선 번호
* **To**: 2차측 모선 번호
* **Tap**: 권선비 (예: 1.03 = 103%, 1.00 = 공칭)

---

## 2. 📤 출력 엑셀 규격 (Output Format)

조류 계산 완료 후 화면의 [엑셀 다운로드] 또는 `/download_result_excel` API를 통해 내려받는 결과 파일입니다.

### ① Bus Results 시트 (모선별 계산 결과)
* **Bus**: 모선 번호
* **Volt (pu)**: 최종 수렴 전압 크기 (pu)
* **Angle (deg)**: 최종 수렴 전압 위상각 (도, °)
* **Pgen (MW)**: 발전 유효전력 (MW)
* **Qgen (MVAR)**: 발전 무효전력 (MVAR)
* **Pload (MW)**: 부하 유효전력 (MW)
* **Qload (MVAR)**: 부하 무효전력 (MVAR)
* **Type**: 모선 종류 (SLACK, PV, PQ)

### ② Line Results 시트 (선로별 조류 및 손실 결과)
* **No.**: 선로 순번
* **Line**: 선로 식별 라벨 (예: `Bus 1 ↔ Bus 2`)
* **From Bus**, **To Bus**: 선로 양단 모선 번호
* **P From (MW)**, **Q From (MVAR)**: From 모선에서 선로로 흐르는 조류
* **P To (MW)**, **Q To (MVAR)**: To 모선에서 선로로 흐르는 조류 (수전 기준 음수)
* **Loss P (MW)**: 선로 유효전력 손실 ($P_{\text{from}} + P_{\text{to}}$)
* **Loss Q (MVAR)**: 선로 무효전력 손실 ($Q_{\text{from}} + Q_{\text{to}}$)

### ③ System Summary 시트 (계통 총괄 요약)
* **Total Generation P / Q**: 계통 총 발전량 (MW / MVAR)
* **Total Load P / Q**: 계통 총 부하량 (MW / MVAR)
* **Total Transmission Loss P / Q**: 계통 총 송전 손실 (MW / MVAR)
* **Iterations**: 뉴턴-랩슨 수렴 반복 횟수 (예: 4회)
* **Slack Bus**: 계통 슬랙 모선 번호
* **Converged**: 수렴 여부 (True / False)
* **Max Mismatch**: 최종 수렴 오차 (pu)

---

## 3. 📁 제공 샘플 파일 목록
1. **`case24_ieee_rts_diagram_aligned.xlsx`** (Primary E2E Reference):
   - **정의**: IEEE RTS-24 데이터를 기반으로 제공 단선도(`sample_diagram_ieee24.jpg`)와 정합되도록 구성한 diagram-aligned 파생 검증 케이스 (derived fixture).
   - **목적**: `Image → Vision → Bus Number Linking → Topology → Excel Mapping → Transformer Electrical Branch Synthesis → AC Newton-Raphson` 전체 E2E 파이프라인 무결성 검증.
   - **주요 제원**: 24모선, 가시 발전기 10기, 유효 부하 17기, 탭 변압기 5개 브랜치 (3-24, 9-11, 9-12, 10-11, 10-12), 기준 슬랙 모선: #13 ($V = 1.0200\,\text{pu}, \theta = 0.0^\circ$), Base MVA: 100.
   - **설비 처리 원칙**: 제공 단선도에 발전기/동기조상기 기호가 보이지 않는 Bus 14는 임의 자동 생성하지 않고 제공 단선도에 표현된 가시 설비 구성과 정합되도록 구성한 diagram-aligned derived fixture의 형태를 유지.
2. **`case24_psse.xlsx`** (Secondary / Legacy Solver Benchmark):
   - **정의**: PSS/E-style 24-bus solver regression fixture로, 엑셀 파서 및 순수 수치해석 솔버 회귀 검증용 벤치마크 케이스.
   - **주요 제원**: 슬랙 모선: #1 ($V = 1.0\,\text{pu}, \theta = 0.0^\circ$), 발전기 11기, 34 브랜치.
3. **`ac_case25.xlsx`**: 25모선 표준 계통 입력 엑셀 (솔버 다모선 검증용).
4. **`sample_case3.xlsx`**: 3모선 표준 계통 튜토리얼 엑셀 (슬랙 모선: #1, 수작업 계산 검증용).
5. **`user_case3.xlsx`**: 사용자 지정 3모선 계통 입력 엑셀.
6. **`sample_diagram_ieee24.jpg`**: E2E 테스트 및 비전 파이프라인 검증용 IEEE 24 RTS 단선도 원본 래스터 이미지.

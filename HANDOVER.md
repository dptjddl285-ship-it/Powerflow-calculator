# 📋 Powerflow Simulator - 개발 및 운영 인수인계서 (Handover Guide)

> **문서 목적**: 다른 컴퓨터에서 본 프로젝트(`my-powersimulator`)를 새로 클론(Clone)하여 즉시 개발, 테스트, 시연을 진행할 수 있도록 환경 구축부터 서버 및 앱 구동, 화면 조작 매뉴얼까지의 전 과정을 상세히 기술합니다.

---

## 1. 프로젝트 요약 및 핵심 구조

| 구분 | 주요 기술 스택 | 설명 |
| :--- | :--- | :--- |
| **Backend API** | Python 3.12, FastAPI, Uvicorn | 도면 이미지 분석, 토폴로지 추출, 조류계산 연산 REST API |
| **Powerflow Engine** | pandapower, NetworkX, SciPy | 전력계통 AC 조류계산(Newton-Raphson), IEEE 14/30 Bus 해석 |
| **Vision & AI** | YOLO11 (PyTorch), OpenCV | 단선도 기기(Bus, Gen, Load, Tr) 인식 및 선로 세선화/연결망 복원 |
| **Frontend App** | Flutter 3.x (Dart), CustomPaint | 모바일/웹 크로스플랫폼 UI, 인터랙티브 회로 캔버스, 결과 대시보드 |

---

## 2. 새 컴퓨터 환경 구축 (Step-by-Step Setup)

### 2.1 사전 요구사항 (Prerequisites)
- **OS**: Windows 10/11, macOS, 또는 Ubuntu Linux
- **Git**: 최신 버전 설치
- **Python**: **Python 3.12** 권장 (3.10 ~ 3.12 호환)
- **Flutter SDK**: 3.22.x 이상 (프론트엔드 작업 시 필수)
- **IDE**: VS Code 또는 Cursor / PyCharm / Android Studio

---

### 2.2 Git 클론 및 저장소 이동

```powershell
# 1. 새 컴퓨터의 작업 디렉터리로 이동 후 클론
git clone https://github.com/hpo200222-rgb/my-powersimulator.git
cd my-powersimulator
```

---

### 2.3 Python 백엔드 환경 설정

```powershell
# 1. 가상환경 생성 (venv 사용 시)
python -m venv .venv

# 2. 가상환경 활성화 (Windows PowerShell)
.venv\Scripts\Activate.ps1
# (macOS/Linux의 경우: source .venv/bin/activate)

# 3. 필수 패키지 설치
pip install --upgrade pip
pip install -r requirements.txt
```

> **PyTorch GPU(CUDA) 가속이 필요한 경우 (선택사항)**:  
> NVIDIA 그래픽카드가 있는 경우 PyTorch 공식 웹사이트 안내에 맞추어 CUDA 버전을 설치합니다:  
> `pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121`

---

### 2.4 Flutter 프론트엔드 환경 설정

```powershell
# 1. frontend_app 디렉터리로 이동
cd frontend_app

# 2. Flutter 의존성 패키지 다운로드
flutter pub get

# 3. 개발 환경 정상 여부 점검
flutter doctor

# 4. 루트 디렉터리로 복귀
cd ..
```

---

## 3. 핵심 실행 및 테스트 방법 (How to Run)

### 3.1 전력 조류계산(PandaPower) 엔진 단독 테스트
백엔드 연동 전, 전력 조류계산 모듈이 정상 동작하는지 즉시 검증할 수 있습니다.

```powershell
# 1. 기본 IEEE 30-Bus 조류계산 및 터미널 요약 출력
python -m backend_api.demo_pandapower

# 2. IEEE 30-Bus 정밀 해석 및 시각화 이미지 생성 (demo_ieee30_rich_powerflow.png 생성)
python -m backend_api.demo_pandapower_advanced

# 3. PandaPower 엔진 통합 검증 테스트
python -m backend_api.test_pandapower_integration
```

---

### 3.2 백엔드 FastAPI 서버 구동
AI 인식과 조류계산 API를 제공하는 메인 서버를 실행합니다.

```powershell
# 프로젝트 루트(my-powersimulator) 디렉터리에서 실행
uvicorn backend_api.server.main_server:app --host 0.0.0.0 --port 8000 --reload
```

- **Swagger API 대화형 문서**: 브라우저에서 `http://localhost:8000/docs` 접속
- **서버 헬스체크**: `http://localhost:8000/api/health`

---

### 3.3 Flutter 프론트엔드 앱 실행

```powershell
cd frontend_app

# 웹 브라우저(Chrome)로 실행
flutter run -d chrome

# 또는 Windows 데스크톱 앱으로 실행
flutter run -d windows
```

---

### 3.4 AI 심볼 인식 및 토폴로지 자동 튜닝(Auto-Tune) 검증

```powershell
# Train 데이터셋 기준 검증 실행 (IoU 0.4)
$env:AUTO_TUNE_MODEL_PATH='runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt'
python -m backend_api.validation_tests.auto_tune_evaluator --split train --module backend_api.line_recognition.logic.vision_logic_topology_hybrid --iou 0.4
```

---

## 4. 화면 및 기능별 조작 매뉴얼 (Screen Walkthrough)

### 4.1 메인 회로 캔버스 조작법
- **기기 배치**: 상단 툴바에서 `모선`, `발전기`, `부하`, `변압기` 칩을 클릭한 후 캔버스 위를 클릭하면 해당 위치에 심볼이 자동 스냅되어 생성됩니다.
- **선로 연결**: 툴바의 `선로연결` 선택 후, 시작 모선 클릭 -> 끝 모선 클릭 시 선로가 자동 연결됩니다.
- **캔버스 이동/확대**: `선택/이동` 모드에서 마우스 드래그(팬) 및 휠 스크롤(줌)으로 자유롭게 탐색할 수 있습니다.

### 4.2 부품별 제원 설정 창 (Properties Dialog)
- 캔버스 위에 배치된 기기를 클릭하면 **제원 설정 팝업 다이얼로그**가 열립니다.
  - **모선(Bus)**: 버스 번호, 기준 전압($V_{pu}$), 초기 위상각($\theta_{deg}$) 입력
  - **발전기(Generator)**: 발전 유효전력($P_{pu}$), 지정 전압($V_{pu}$), **슬랙 모선(Slack Bus) 토글 스위치**
  - **부하(Load)**: 유효 부하($P_{pu}$), 무효 부하($Q_{pu}$)
  - **선로(Line)**: 저항($R_{pu}$), 리액턴스($X_{pu}$)
- `저장` 버튼을 누르면 입력값이 즉시 반영되며 화면 상의 정보 라벨이 갱신됩니다.

### 4.3 도면 사진 분석 창 (Image Upload Dialog)
- 툴바의 보라색 **[도면 사진 분석]** 버튼 클릭
- 단선도 이미지 파일(.jpg, .png)을 선택하면 FastAPI 서버의 AI 엔진으로 전송되어 기기와 선로를 자동 추출합니다.

### 4.4 Swagger 웹 대시보드 창 (`/docs`)
- 브라우저에서 `http://localhost:8000/docs` 접속
- `/run_simulation`, `/ieee_cases`, `/render_ieee_image/case14` 등의 API를 [Try it out] 버튼으로 직접 호출하여 반환 데이터 및 렌더링 이미지를 실시간으로 검증할 수 있습니다.

---

## 5. 디렉터리 및 주요 파일 안내

```
my-powersimulator/
│
├── PRD.md                           # 전체 제품 요구사항 정의서 (마스터 플랜)
├── HANDOVER.md                      # 새 PC 개발자 인수인계 가이드 (본 문서)
├── README.md                        # 저장소 메인 소개 및 빠른 시작
├── requirements.txt                 # Python 전체 종속성 목록
├── .gitignore                       # Git 제외 규칙
│
├── 01_PRD & 워드 정리/               # 대회 기획서 및 문서 원본
├── 02_결과 모음들/                  # 시뮬레이션 및 인식 결과 샘플
├── 03_AI_Training_History/          # 과거 Colab 학습 히스토리 및 모델
├── 04_Assets_Images/                # UI 에셋 및 테스트용 단선도 원본
├── 05_Diagnostic_Scripts/           # 진단 및 디버깅 스크립트 모음
│
├── backend_api/                     # [백엔드 & 전력해석 핵심 엔진]
│   ├── server/                      # FastAPI 서버 라우터 및 엔드포인트
│   │   ├── main_server.py           # 메인 API 서버 진입점
│   │   └── pandapower_engine.py     # PandaPower 연동 전력해석 서비스
│   ├── core/                        # 전력 알고리즘 & 비전 로직 코어
│   ├── icon_recognition/            # YOLO 심볼 인식 모델 및 가중치
│   │   └── models/best.pt           # 최신 학습 완료 가중치
│   ├── line_recognition/            # 전선 세선화 및 토폴로지 추출
│   │   └── logic/vision_logic_topology_hybrid.py # 하이브리드 토폴로지 알고리즘
│   ├── validation_tests/            # 자동 평가 및 검증 스위트
│   └── demo_pandapower_advanced.py  # PandaPower 종합 데모 스크립트
│
└── frontend_app/                    # [프론트엔드 Flutter 애플리케이션]
    ├── lib/                         # Dart UI 코드
    │   ├── main.dart                # 앱 진입점
    │   ├── screens/                 # 회로 캔버스, 파라미터 설정, 결과 화면
    │   └── services/                # 백엔드 REST API 통신 모듈
    └── pubspec.yaml                 # Flutter 패키지 설정
```

---

## 6. 핵심 모델 가중치(Weights) 체크포인트 위치

1. **메인 심볼 인식 가중치 (Primary Model)**:
   - 경로: `backend_api/icon_recognition/models/best.pt`
   - 역할: Bus, Generator, Load, Transformer 4개 클래스 객체 검출.
2. **Auto-Tune 평가용 가중치 (Auto-tune Benchmark)**:
   - 경로: `runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt`
   - 역할: Train 99.29% baseline 달성 체크포인트.

---

## 7. 문제 해결 (Troubleshooting & FAQ)

### Q1. `ModuleNotFoundError: No module named 'backend_api'` 발생 시
- **원인**: Python 실행 시 루트 디렉터리가 `PYTHONPATH`에 잡히지 않은 경우.
- **해결책**:
  ```powershell
  # Windows PowerShell
  $env:PYTHONPATH = (Get-Location).Path
  ```

### Q2. FastAPI 서버 실행 시 `Port 8000 already in use` 에러
- **해결책**: 다른 포트를 지정하여 실행합니다:
  ```powershell
  uvicorn backend_api.server.main_server:app --port 8080 --reload
  ```

### Q3. Flutter 실행 시 백엔드 API 주소 설정
- 로컬 에뮬레이터 또는 다른 기기에서 접속 시 `frontend_app` 내 API 설정에서 `http://10.0.2.2:8000` (안드로이드 에뮬레이터) 또는 PC의 실제 로컬 IP(`http://192.168.x.x:8000`)로 설정해야 합니다.

# ⚡ Powerflow Simulator (VisionFlow)

> **Edge AI 기반 전력계통 단선도(SLD) 자동 인식 & 원스톱 조류계산(Power Flow) 시뮬레이션 시스템**

[![Python 3.12](https://img.shields.io/badge/Python-3.12-blue.svg)](https://www.python.org/)
[![FastAPI](https://img.shields.io/badge/Backend-FastAPI-009688.svg)](https://fastapi.tiangolo.com/)
[![pandapower](https://img.shields.io/badge/Simulation-pandapower-green.svg)](https://www.pandapower.org/)
[![Flutter](https://img.shields.io/badge/Frontend-Flutter-02569B.svg)](https://flutter.dev/)
[![YOLO11](https://img.shields.io/badge/AI-YOLO11-orange.svg)](https://github.com/ultralytics/ultralytics)

---

## 📌 주요 문서 바로가기

- 📄 **[제품 요구사항 정의서 (PRD.md)](./PRD.md)**: 전체 시스템 기획, 아키텍처, 비전 파이프라인, 로드맵
- 🛠 **[다른 컴퓨터 개발 및 인수인계서 (HANDOVER.md)](./HANDOVER.md)**: 새 컴퓨터 환경 세팅, 실행 명령어, 문제 해결 가이드

---

## 🌟 핵심 기능 (Key Features)

1. **AI 단선도 심볼 객체 검출 (Symbol Detection)**
   - YOLO11 기반 4대 핵심 기기(`Bus`, `Generator`, `Load`, `Transformer`) 고정밀 검출
   - 괴물 박스(False Positive) 방지 및 신뢰도 기반 필터링

2. **컴퓨터 비전 토폴로지 복원 (Port-aware Topology)**
   - OpenCV 모폴로지 세선화(Skeletonization) 및 선로 연결망 그래프 자동 복원
   - 기기 단자(Port) 기반 연결성 매핑

3. **산업 표준급 전력 조류계산 (pandapower Integration)**
   - AC Power Flow (Newton-Raphson) 알고리즘 탑재
   - IEEE 14, 30 Bus 표준 계통 및 사용자 정의 계통의 전압/위상각/선로 조류/과부하율 계산

4. **인터랙티브 회로 캔버스 (Interactive Canvas)**
   - Flutter CustomPaint 기반의 그래픽 에디터
   - 터치 및 드래그를 통한 회로 보정(Human-in-the-Loop) 및 엑셀 파라미터 매핑

---

## 🚀 빠른 시작 (Quick Start)

### 1. 환경 설정 및 패키지 설치
```bash
# 저장소 클론
git clone https://github.com/hpo200222-rgb/my-powersimulator.git
cd my-powersimulator

# Python 가상환경 생성 및 의존성 설치
python -m venv .venv
.venv\Scripts\Activate.ps1   # (Linux/Mac: source .venv/bin/activate)
pip install -r requirements.txt
```

### 2. PandaPower 조류계산 시뮬레이션 데모 실행
```bash
python -m backend_api.demo_pandapower_advanced
```
*(실행 시 IEEE 30-Bus 계통 해석 결과 및 `backend_api/demo_ieee30_rich_powerflow.png` 시각화 이미지가 생성됩니다.)*

### 3. 백엔드 FastAPI 서버 구동
```bash
uvicorn backend_api.server.main_server:app --host 0.0.0.0 --port 8000 --reload
```
- Swagger API 문서: [http://localhost:8000/docs](http://localhost:8000/docs)

### 4. 프론트엔드 Flutter 앱 구동
```bash
cd frontend_app
flutter pub get
flutter run -d chrome   # 또는 flutter run -d windows
```

---

## 📂 프로젝트 구조

```
my-powersimulator/
├── PRD.md                           # 전체 제품 요구사항 정의서
├── HANDOVER.md                      # 인수인계 및 환경 구축 가이드
├── requirements.txt                 # 백엔드 종속성 목록
├── backend_api/                     # FastAPI 서버 & PandaPower 해석 & 비전 엔진
│   ├── server/                      # 메인 API 라우터 (main_server.py)
│   ├── core/                        # 전력 알고리즘 & 비전 로직 코어
│   ├── icon_recognition/            # YOLO 심볼 모델 (models/best.pt)
│   └── line_recognition/            # 토폴로지 추출 파이프라인
├── frontend_app/                    # Flutter 프론트엔드 모바일/웹 앱
├── 01_PRD & 워드 정리/               # 초기 기획서 및 문서 원본
├── 02_결과 모음들/                  # 시뮬레이션 결과 자료
└── 04_Assets_Images/                # 단선도 샘플 이미지
```

---

## 📜 라이선스

본 프로젝트는 연구 및 대회 참가를 목적으로 개발되었습니다.
자세한 실행 및 세부 내용은 [HANDOVER.md](./HANDOVER.md)를 확인해 주세요.

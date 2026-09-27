# ⚡ PowerLens

<div align="center">

![Python](https://img.shields.io/badge/Python-3.11+-3776AB?style=for-the-badge&logo=python&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-Web-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-0.100+-009688?style=for-the-badge&logo=fastapi&logoColor=white)
![YOLO](https://img.shields.io/badge/YOLO11-Computer_Vision-00FFFF?style=for-the-badge&logo=yolo&logoColor=black)
![Gemini](https://img.shields.io/badge/Gemini_Vision-AI_Evidence-orange?style=for-the-badge&logo=google&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

**지능형 전력 단선도(Single-Line Diagram) 디지털화 및 AC 조류계산 플랫폼**<br/>
*AI Vision 기반 객체·선로 자동 인식, 4단계 Human-in-the-Loop 검수 게이트, 엑셀 계통 제원 교차 검증 및 Full AC Newton-Raphson 수치해석*

</div>

---

## 📌 Overview (개요)

전력 계통 해석(Power System Analysis)을 위한 전산망 데이터를 구축할 때, 도면(Single-Line Diagram)을 육안으로 확인하며 수십~수백 개의 모선 번호, 송전선로 임피던스, 발전기 및 부하 제원을 수치해석 툴에 일일이 수작업으로 타이핑하는 과정은 수 시간 이상의 노동을 필요로 하며 휴먼 에러로 인한 계통 해석 오류를 빈번하게 유발합니다.

**PowerLens**는 래스터 도면 이미지로부터 AI Vision과 OpenCV 기하 검출기를 통해 모선, 발전기, 부하, 변압기, 선로를 자동 추출하고, 4단계 인간-AI 협업 검수 게이트(Review Gate)를 거쳐 검증된 디지털 계통망을 확정한 뒤, 엑셀 제원과의 교차 검증을 거쳐 자체 개발한 고정밀 **Full AC Newton-Raphson 조류계산**을 원스톱으로 수행하는 지능형 전력 엔지니어링 웹 CAD 플랫폼입니다.

---

## 🔄 Core Pipeline (핵심 파이프라인)

$$\text{Single-Line Diagram} \longrightarrow \text{Vision} \longrightarrow \text{Review} \longrightarrow \text{Verified Network} \longrightarrow \text{Excel Cross Validation} \longrightarrow \text{AC Power Flow}$$

1. **Single-Line Diagram**: 래스터 도면 이미지(`.png`, `.jpg`, `.jpeg`) 입력.
2. **Vision**: YOLO11 심볼 검출 + OpenCV 선로 골격화 추적 + Set-of-Mark 기반 Gemini Vision 모선 번호 판독.
3. **Review**: 객체 검수 $\rightarrow$ 모선 번호 매핑 $\rightarrow$ 선로 결선 $\rightarrow$ 최종 검증의 4단계 게이트웨이.
4. **Verified Network**: 불변 `VerifiedSLD` 스키마 확정 및 CAD 캔버스 자동 배치 (부하 4방향 회전 스냅).
5. **Excel Cross Validation**: 계통 제원 엑셀(.xlsx)과의 교차 대조, 설비 불일치 식별 및 수리 제안(Repair Proposal).
6. **AC Power Flow**: Dense NumPy 배열 기반 복소 어드미턴스 행렬($Y_{\text{bus}}$) 및 야코비안 풀이를 통한 조류계산 및 선로 흐름 벡터 가시화.

---

## ✨ Key Features (주요 기능)

- **SLD Object Detection**: YOLO11 파인튜닝 모델과 OpenCV 기하 알고리즘을 융합한 하이브리드 심볼 인식.
- **Bus Number / Topology Reconstruction**: Set-of-Mark 콜라주를 통한 모선 번호 시각 판독 및 픽셀 스켈레톤화 기반 선로 토폴로지 추출.
- **Staged Review (Object / Bus / Connection Review)**: 오탐과 미탐을 단계별로 검증하는 4단계 체계적인 검수 환경.
- **Lensy-guided Human-in-the-Loop Workflow**: 대화형 조수(Lensy)의 시각적 UI 네온 점등 안내와 엔지니어의 명시적 승인 권한 결합.
- **Deterministic Validation**: 외부 LLM 의존 없이 로컬 규칙과 불변 스키마로 계통 무결성을 검증하는 기술 게이트.
- **Excel Cross Validation**: 도면 설비와 엑셀 제원 간 모선/선로/발전기/부하 일치 여부 정밀 대조.
- **Generator/Load Repair Proposal**: 도면 미검출 발전기/부하에 한정된 안전한 수리 제안 (승인 시에만 반영, 모선/선로/변압기 자동 생성 불가).
- **Transformer Electrical Branch Reconstruction**: 시각적 가상 인입선 바이패스 및 다중 변압기 2-Port 전기적 브랜치($R, X, B, \text{tap}$) 자동 합성.
- **Full AC Newton-Raphson Solver**: 임의의 기본값(Fallback)을 배제하고 $Y_{\text{bus}}$ 및 야코비안을 정밀 풀이하는 자체 수치해석 엔진.

---

## 🚀 Quick Start (빠른 시작)

### 1. 요구 사항
- Python 3.11+
- Flutter 3.19+ (Web 지원)
- Google Chrome 또는 Chromium 계열 브라우저
- Google Gemini API Key (모선 번호 OCR 및 질의응답 시 `.env` 설정)

### 2. 원클릭 실행 (Windows 권장)
```bash
# 1) 파이썬 의존성 설치 (최초 1회)
pip install -r backend_api/requirements.txt

# 2) 원클릭 통합 실행 (백엔드 + 프론트엔드 동시 가동 & 브라우저 자동 오픈)
python scripts/run_powerlens.py
```
- 브라우저 접속 주소: [http://localhost:58640](http://localhost:58640)
- 백엔드 API 문서: [http://localhost:8000/docs](http://localhost:8000/docs)

### 3. 개별 서버 수동 실행
```bash
# [터미널 1] FastAPI 백엔드 서버 (포트 8000)
python backend_api/main_server.py

# [터미널 2] Flutter Web 프론트엔드 정적 서빙 (포트 58640)
python scripts/frontend_server.py
```

### 4. 테스트 스위트 실행
```bash
# 프론트엔드 테스트 (215개 테스트 전수 통과)
cd frontend_app
flutter test

# 백엔드 테스트 (242개 테스트 전수 통과)
cd ../backend_api
pytest -q
```

---

## 📚 Documentation (핵심 문서 모음)

심사 및 기술 검토를 위한 5대 핵심 문서는 다음과 같습니다:

1. 📐 **[시스템 구성도 (docs/SYSTEM_ARCHITECTURE.md)](docs/SYSTEM_ARCHITECTURE.md)**: 전체 시스템 블록 다이어그램, 계층별 데이터 흐름 및 AI-게이트-인간 역할 정의.
2. 📄 **[상세 기술 문서 (docs/TECHNICAL_DOCUMENTATION.md)](docs/TECHNICAL_DOCUMENTATION.md)**: 비전 파이프라인, 검수 아키텍처, 엑셀 연계, 변압기 모델링, AC Newton-Raphson 솔버 기술 명세.
3. 🔄 **[워크플로 정의서 (docs/WORKFLOW.md)](docs/WORKFLOW.md)**: 도면 입력부터 조류계산 결과 도출까지의 단계별 INPUT, PROCESS, OUTPUT, BLOCKER, HUMAN ACTION 명세.
4. 🧪 **[기술 검증 보고서 (docs/EVALUATION.md)](docs/EVALUATION.md)**: 26장 홀드아웃 객체 검출 F1(98.01%), 24-bus reference case 수렴 검증, 자동화 테스트 통과 결과.
5. 📂 **[전체 문서 허브 (docs/README.md)](docs/README.md)**: 특허 명세서, 내부 인수인계 가이드, 스크린샷 갤러리 인덱스.

---

## 🧪 Validation Summary (검증 요약)

- **Object Detection F1-Score**: **98.01%** (Precision 98.07%, Recall 97.95% | 26장 독립 홀드아웃 단선도 테스트셋, IoU $\ge 0.40$ 기준).
- **Primary Power Flow Reference**: 24-bus diagram-aligned reference case (`case24_ieee_rts_diagram_aligned.xlsx`)에서 허용 오차 $10^{-4}$ 조건 기준 **4 iterations 내 수렴** (슬랙 모선 Bus 13 발전량 $P \approx 188.25\,\text{MW}, Q \approx 94.60\,\text{MVAR}$, 계통 손실 $P_{\text{loss}} \approx 52.25\,\text{MW}$).
- **Secondary Solver Benchmark**: PSS/E 스타일 24모선 벤치마크(`case24_psse.xlsx`)에서 4회 반복 수렴 및 전력 수지 평형($\Delta P = 0.0\,\text{MW}$) 확인.
- **자동화 테스트 스위트**: 백엔드 242개 테스트 및 프론트엔드 215개 테스트 **100% 전수 통과**, 정적 분석 0 errors, 0 warnings 달성.

*(※ 상세 수치 및 분석 근거는 [`docs/EVALUATION.md`](docs/EVALUATION.md)를 참조하십시오).*

---

## 📄 License

This project is licensed under the MIT License.

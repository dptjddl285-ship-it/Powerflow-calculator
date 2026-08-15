# 📋 프로젝트 마스터 플랜 및 제품 요구사항 정의서 (VisionFlow / PowerSimulator)

### Edge AI 기반 전력계통 단선도(SLD) 인식, 합성 도면 생성 및 정밀 조류계산 자동화 시스템

---

> [!IMPORTANT]
> **본 문서의 목적 (Purpose of this Document)**
> 
> 이 문서는 **PowerSimulator (VisionFlow)** 프로젝트의 전체 로드맵, 핵심 아키텍처, AI 비전 인식 및 전력계통 해석/시각화 엔진의 기능 명세를 정의한 통합 PRD(Product Requirements Document)입니다.

---

## 📌 1. 프로젝트 최종 목표 (Project Goal)

| 항목 | 내용 |
| :--- | :--- |
| **최종 비전** | 수작업으로 진행되던 조류계산(Power Flow) 모델링을 AI 이미지 인식 및 자동화 도면 생성 기술과 결합하여 전력계통 엔지니어링 워크플로우를 극대화 |
| **핵심 결과물 1** | **도면 사진 인식 & 조류계산**: 회로도 사진(교과서/도면)을 업로드하면 AI가 기기와 선로를 파악해 조류계산까지 원스톱 처리하는 앱 |
| **핵심 결과물 2** | **교과서 규격 단선도 생성기**: IEEE 및 임의 결선의 전기도면 규격 흑백 단선도를 코드로 자동 생성 및 YOLO 합성 데이터셋 구축 |
| **핵심 결과물 3** | **정밀 조류계산 & 단선도 히트맵**: Pandapower 기반 AC Power Flow(Newton-Raphson) 및 전압/부하율 컬러맵 오버레이 시각화 |

---

## 🛠 2. 필요 프로그램 및 기술 스택 (Tech Stack)

### 2.1. 인공지능 & 영상 처리 (AI & Computer Vision)
* **YOLO11 (Ultralytics):** 도면 이미지에서 4대 핵심 심볼(Bus, Generator, Load, Transformer)의 위치를 정확하게 찾아내는 객체 인식 AI.
* **Roboflow & Synthetic Generator:** AI 학습용 도면 라벨링 관리 및 코드로 생성하는 정밀 합성 도면 데이터셋 파이프라인.
* **OpenCV (Python):** 기기 마스킹 후 남은 전선(Wire) 뼈대 추적 및 하이브리드 토폴로지 연결망 추출.

### 2.2. 백엔드 & 전력계통 알고리즘 (Backend & Algorithm)
* **FastAPI (Python):** 비전 분석, 엑셀 파싱, 조류계산 및 단선도 이미지 스트림을 제공하는 고성능 비동기 API 서버.
* **pandapower (Python):** IEEE 표준 계통 로드, AC/DC 조류계산(Newton-Raphson), 전압/조류 손실 정밀 산출 및 단선도 히트맵 렌더링 엔진.

### 2.3. 프론트엔드 앱 (Frontend App)
* **Flutter (Dart):** 크로스 플랫폼 모바일/데스크톱 UI.
* **Canvas API (CustomPaint):** 인터랙티브 회로 에디터 및 조류계산 결과 실시간 그래픽 오버레이.

---

## 🚀 3. 프로젝트 개발 진행 순서 (Development Roadmap)

### [Step 1] 데이터 수집, 라벨링 및 합성 도면 생성
- IEEE 14, 30 Bus 등 표준 단선도 수집 및 `synthetic_circuit_generator.py`를 활용한 교과서 스타일 합성 도면/라벨 자동 생성

### [Step 2] AI 객체 인식 모델 훈련 (YOLO11)
- 4대 부품(Bus, Generator, Load, Transformer) 검출 모델 학습 및 NMS 파라미터 최적화

### [Step 3] 백엔드 및 회로 연결망(OpenCV) 추출 개발
- 기기 마스킹 후 골격화(Skeletonization)를 통한 선로 연결 토폴로지 JSON 자동 추출

### [Step 4] 프론트엔드 앱 기초 뼈대 만들기 (Flutter)
- 도면 업로드, 카메라 촬영, 백엔드 통신 인터페이스 구축

### [Step 5] 인터랙티브 회로 캔버스 및 수동 에디터 구현 (Human-in-the-Loop)
- 추출된 JSON을 캔버스에 렌더링하고, 사용자가 직접 마우스/터치로 수정 및 결선 추가 가능한 에디터

### [Step 6] 엑셀 매핑 및 Pandapower 조류계산 연동 (최종 통합)
- 기기 상세 파라미터 매핑 ➔ Pandapower AC 조류계산 ➔ 모선 전압/선로 부하율 히트맵 단선도 실시간 출력

---

## ⚡ 4. 고도화 기능 상세 명세 (Advanced Engines)

### 4.1. Pandapower 조류계산 & 시각화 엔진 ([`pandapower_engine.py`](file:///C:/Users/hpo20/orca/workspaces/Powerflow-calculator/antigravity-independent-feedback-loop/backend_api/core/pandapower_engine.py))
1. **커스텀 네트워크 자동 빌드**: Flutter 캔버스/Vision JSON 데이터를 Pandapower Net으로 실시간 변환
2. **IEEE 표준 계통 지원**: IEEE 4, 14, 30, 39, 57, 118-Bus 즉시 로드 및 해석
3. **단선도 히트맵 시각화**:
   - 모선 전압(p.u.) ➔ Coolwarm 컬러맵 & 전압 수치 라벨 오버레이
   - 선로 부하율(Loading %) ➔ Autumn 컬러맵 & 과부하 상태 경고

### 4.2. 교과서 스타일 단선도 생성기 ([`synthetic_circuit_generator.py`](file:///C:/Users/hpo20/orca/workspaces/Powerflow-calculator/antigravity-independent-feedback-loop/backend_api/synthetic_circuit_generator.py))
- 전력계통 교과서(`auto_tune_test_images`)와 동일한 흑백 선화 규격의 회로도 자동 생성
- 수평/수직 모선 바, 정현파 발전기 심볼, 복소전력($P+jQ$) 부하 심볼, 2-Circle($\Phi\Phi$) 변압기 심볼, 절곡 배선 지원
- 다양한 결선(루프형, 방사상, 메시형) 파라메트릭 생성 지원

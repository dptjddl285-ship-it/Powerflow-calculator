# 📚 PowerLens Documentation Hub (문서 허브)

PowerLens 프로젝트의 시스템 설계, 기술 명세, 워크플로 정의, 성능 검증, 특허 명세서 및 내부 가이드 모음입니다.

---

## 🏆 핵심 심사 제출 문서 (Core Submission Documents)

심사위원 및 기술 검토자가 확인해야 하는 5대 핵심 문서는 다음과 같습니다:

1. ⚡ **[프로젝트 메인 개요 (README.md)](../README.md)**
   - 프로젝트 목적, 핵심 파이프라인($\text{SLD} \rightarrow \text{Vision} \rightarrow \text{Review} \rightarrow \text{Verified} \rightarrow \text{Excel} \rightarrow \text{PowerFlow}$), 주요 특징 및 빠른 시작 가이드.
2. 📐 **[시스템 구성도 (docs/SYSTEM_ARCHITECTURE.md)](./SYSTEM_ARCHITECTURE.md)**
   - 공고 요구 '시스템 구성도' 담당. 개념 흐름도, 상세 블록 다이어그램, 계층별 데이터 흐름 및 AI-게이트-인간 역할 분담 명세.
3. 📄 **[상세 기술 문서 (docs/TECHNICAL_DOCUMENTATION.md)](./TECHNICAL_DOCUMENTATION.md)**
   - 공고 요구 '기술 문서' 담당. 비전 파이프라인, 4단계 검수 아키텍처, 엑셀 연계, 변압기 모델링, Full AC Newton-Raphson 솔버 기술 명세.
4. 🔄 **[워크플로 정의서 (docs/WORKFLOW.md)](./WORKFLOW.md)**
   - 공고 요구 '워크플로 정의 파일' 담당. 도면 업로드부터 조류계산 결과 도출까지 각 단계별 INPUT, PROCESS, OUTPUT, BLOCKER, HUMAN ACTION 정의.
5. 🧪 **[기술 검증 및 성능 평가 보고서 (docs/EVALUATION.md)](./EVALUATION.md)**
   - 공고 요구 '평가 자료' 담당. 26장 홀드아웃 단선도 객체 검출 F1(98.01%), 24-bus reference case 수치해석 수렴 검증, 457개 자동화 회귀 테스트 결과.

---

## 📂 보조 및 참고 문서 디렉토리 (Supplementary Folders)

- 🖼️ **[images/](./images/)**: 홈 화면, Lensy AI 어시스턴트, 4단계 검수실, Web CAD 전력조류 애니메이션 등 대표 시스템 UI 스크린샷 모음.
- 📜 **[patent/](./patent/)**:
  - `PowerLens_특허명세서_공식출원용.md`: AI 기반 단선도 객체 인식, 대화형 CAD 검수 인터페이스 및 수치해석 연동 시스템 특허 출원 명세서.
- 🔒 **[internal/](./internal/)**:
  - `POWERLENS_AGENT_RULES.md`: 시스템 개발 및 에이전트 동작 시 유지해야 하는 16대 불변 규칙 (Source of Truth).
  - `TEAM_HANDOFF.md`: 팀 인수인계 및 개발자용 온보딩 가이드.
  - `POWERLENS_HANDOFF_2026-09-27.md`: 2026-09-27 기준 통합 인수인계 이력.
- 🗄️ **[archive/](./archive/)**:
  - `PROGRESS_REPORT.md`: 초기 개발 진척 및 마일스톤 이력 기록.
  - `PROGRESS_REPORTING_RULES.md`: 개발 진행 보고 양식 및 규칙 아카이브.

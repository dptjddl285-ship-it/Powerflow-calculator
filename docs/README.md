# 📚 PowerLens Documentation Hub

PowerLens Pro 프로젝트의 시스템 설계, 팀 인수인계, 특허 명세서 및 기술 검증 문서 모음입니다.

---

## ⚡ 최상위 핵심 문서 (Root Documentation)

- [⚡ 프로젝트 메인 개요 (README.md)](../README.md): 프로젝트 비전, 빠른 시작(Quick Start), 아키텍처 다이어그램
- [🧪 기술 검증 보고서 (EVALUATION.md)](../EVALUATION.md): 26장 SLD 벤치마크 (F1 98.01%), AC Newton-Raphson 수렴 및 전력수지 오차 검증
- [🤖 에이전트 워크플로우 (AGENTIC_WORKFLOW.md)](../AGENTIC_WORKFLOW.md): 결정론적 Supervisor, LocalRulePlanningProvider, PatchPreview 및 안전 실행 체계
- [👁️ 비전 파이프라인 (VISION_PIPELINE.md)](../VISION_PIPELINE.md): YOLO11 + CV 하이브리드 검출기, 모선 번호 결합 및 토폴로지 추출

---

## 📂 세부 기술 및 인수인계 문서 (Docs Index)

- 📐 **[SYSTEM_ARCHITECTURE_AND_TECHNICAL_DOCS.md](./SYSTEM_ARCHITECTURE_AND_TECHNICAL_DOCS.md)**
  - 모듈별 기술 명세서, GraphDocument 데이터 구조, 4단계 검수 게이트 및 REST API 전체 규격서
- 👥 **[TEAM_HANDOFF.md](./TEAM_HANDOFF.md)**
  - 신규 팀원 및 평가자를 위한 전체 시스템 개요, 작업 절차, UI 구조 및 대표 검증 시나리오 인수인계 가이드
- 📜 **[patent/PowerLens_특허명세서_공식출원용.md](./patent/PowerLens_특허명세서_공식출원용.md)**
  - AI 기반 단선도 객체 인식, 대화형 CAD 검수 인터페이스 및 수치해석 연동 시스템 특허 출원 명세서
- 🖼️ **[handoff/screenshots/](./handoff/screenshots/)**
  - 홈 화면, Lensy AI 어시스턴트, 4단계 검수 게이트(객체·모선·선로·완결), CAD 전력조류 애니메이션, 수치해석 결과 모달 등 대표 스크린샷 8종
- 🔒 **[internal/POWERLENS_AGENT_RULES.md](./internal/POWERLENS_AGENT_RULES.md)**
  - 시스템 개발 및 에이전트 동작 시 반드시 유지해야 하는 16대 프로젝트 불변 규칙 (Source of Truth)
- 🗄️ **[archive/](./archive/)**
  - `PROGRESS_REPORT.md`: 초기 개발 진척 및 마일스톤 이력 기록
  - `PROGRESS_REPORTING_RULES.md`: 개발 진행 보고 양식 및 규칙 아카이브

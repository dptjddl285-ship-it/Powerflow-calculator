# PowerLens Project Rules

## 1. Product Direction

PowerLens는 전력계통 단선도를 입력하여:

도면 입력
→ 객체 인식
→ 객체 검수
→ 모선 번호 확인
→ 결선 검수
→ 전기적/토폴로지 검증
→ 검증된 회로 생성
→ 계통 제원 연결
→ 전력조류계산
→ 결과 확인

까지 이어지는 Web-based 전력계통 분석 시스템이다.

PowerLens는 별도의 Desktop/Mobile 앱을 각각 만드는 것이 아니라
하나의 Flutter Web App으로 개발한다.

대회 시연의 기준 환경은 Desktop Web이지만,
동일한 URL에서:

- Desktop
- Laptop
- Tablet
- Mobile Browser

모두 실제 사용 가능해야 한다.

Native Android/iOS 앱 개발은 현재 범위에서 제외한다.

---

## 2. First-Time User UX

처음 사용하는 사람이 설명서 없이 사용할 수 있어야 한다.

사용자가 항상 알 수 있어야 하는 것:

1. 지금 어디에 있는가?
2. 지금 무엇을 해야 하는가?
3. 왜 다음 단계로 갈 수 없는가?
4. 다음에 무엇을 하면 되는가?

내부 개발 구조를 사용자가 외워야 하는 UI는 실패한 UI로 간주한다.

One Screen, One Primary Action 원칙을 우선한다.

빈 화면에서는
가장 중요한 첫 행동 하나가 명확하게 보여야 한다.

---

## 3. Reference-First UI

UI/UX를 임의 감각으로 설계하지 않는다.

다음 실제 UX 원칙을 참고한다:

- Flutter Adaptive / Responsive 공식 가이드
- Material 3
- Samsung SmartThings
- KakaoTalk 등 대중적인 Consumer App
- Google Drive / Google Photos의 Upload/Progress/Error UX
- Microsoft Fluent 계열 업무형 Web UI
- WCAG 기본 접근성/터치 기준

외형을 그대로 복제하지 않는다.

다음 요소를 참고한다:

- 명확한 Primary Action
- 상태를 한눈에 파악
- 복잡한 기능은 필요할 때만 노출
- 친숙한 Navigation
- 자연스러운 Error Recovery
- 사용자에게 다음 행동을 제안

PowerLens가 개발용 Tool처럼 보이지 않고
실제로 사용할 수 있는 Product처럼 느껴져야 한다.

---

## 4. PowerLens AI Agent — Core Role

PowerLens AI Agent는 단순 FAQ Chatbot이 아니다.

또한 Gemini가 YOLO/OpenCV/전력조류계산을 대체하는 구조도 아니다.

PowerLens AI는:

"현재 PowerLens 전체 파이프라인의 상태를 이해하고,
각 분석/검증 도구의 결과를 관찰한 뒤,
사용자에게 다음 행동을 안내하고,
필요한 경우 Human 확인을 요청하며,
검증 과정을 조율하는 상위 Agent"

이다.

---

## 5. Technical AI Roles

### Vision / Detection

실제 회로도 객체 인식은:

- YOLO
- OpenCV
- OCR/VLM when appropriate

등 실제 Vision 엔진이 담당한다.

Gemini가 근거 없이 객체나 Bounding Box를 만들어서는 안 된다.

### Electrical / Topology Validation

실제 결선과 전기적 구조의 검증은:

- Connection tracing
- Electrical rules
- Topology validation
- Deterministic validation logic

을 우선한다.

### Power Flow

실제 전력조류계산은
Newton-Raphson 등 기존 계산 엔진이 담당한다.

LLM이 수치 계산 결과를 임의 생성해서는 안 된다.

---

## 6. Gemini Agent Role

Gemini는 PowerLens의 상위 reasoning/orchestration Agent로 사용한다.

Gemini가 반드시 이해해야 하는 것:

- PowerLens의 목적
- 전체 Workflow
- 객체 검출 엔진의 역할
- 각 검출 결과의 의미
- 검출 엔진의 한계
- Bus Mapping의 의미
- Connection Review의 의미
- Topology Validation의 의미
- Final Verification 조건
- Excel/계통 제원이 필요한 이유
- Power Flow 실행 전 조건
- 현재 App Context
- 현재 Blocker
- Human approval policy

Gemini는 단순히:
"너는 전력계통 전문가다"
수준의 Prompt로 사용하지 않는다.

PowerLens 프로젝트 자체를 이해해야 한다.

---

## 7. Agent Decision Policy

Agent는 현재 evidence/state를 바탕으로 다음 중 하나를 선택한다.

### A. Proceed

충분한 근거가 있고
미해결 문제가 없다면:

→ 다음 단계 진행을 안내한다.

### B. Human Check

결과가 애매하거나
confidence/evidence가 부족하다면:

→ 해당 항목만 사용자에게 확인을 요청한다.

### C. Block

전기적/토폴로지 모순 또는
필수 정보 누락이 있다면:

→ 다음 단계 진행을 막고 이유와 해결 방법을 알려준다.

### D. Unknown

근거가 충분하지 않다면:

→ 추측하지 않는다.
→ 사용자 확인 또는 추가 분석을 요청한다.

---

## 8. Human-in-the-Loop

PowerLens의 핵심 구조:

AI 분석
→ Agent 판단
→ 필요 시 Human 확인/수정
→ 다시 검증
→ 다음 단계

중요한 회로 변경은 사용자 모르게 자동 실행하지 않는다.

사용자 확인이 필요한 예:

- 객체 삭제
- 객체 종류 변경
- Bus 번호 변경
- Connection 변경
- 계통 제원 변경
- 회로 구조 변경

Human 수정 이후에는 다시 검증해야 한다.

---

## 9. AI Agent User Experience

PowerLens AI는 기술적으로 정확하면서 동시에 친근해야 한다.

사용자는 자연스럽게 다음과 같이 질문할 수 있어야 한다.

- "나 이제 뭐 해?"
- "지금 어디까지 됐어?"
- "왜 다음으로 못 넘어가?"
- "여기 확인할 거 있어?"
- "이거 그냥 다음으로 가도 돼?"
- "엑셀은 왜 넣어야 해?"
- "지금 문제가 뭐야?"
- "결과 좀 설명해줘."

Agent는 실제 현재 App Context를 기반으로 답한다.

내부 코드 상태를 단순히 읽어주는 식으로 답하지 않는다.

예:

좋지 않은 답변:
"SUSPICIOUS_COUNT=2 이므로 Gate Fail입니다."

좋은 답변:
"검토가 필요한 객체가 2개 남아 있어요.
이 두 항목만 확인하면 모선 번호 확인 단계로 넘어갈 수 있습니다."

---

## 10. Proactive Guidance

PowerLens AI는 사용자가 질문할 때만 등장하는 Chatbot이 아니다.

중요한 단계 전환 시
한 번씩 짧게 다음 행동을 안내할 수 있다.

예:

객체 분석 완료:
"객체 분석이 끝났어요. 확인이 필요한 항목만 같이 볼까요?"

객체 검수 완료:
"객체 확인이 끝났습니다. 이제 모선 번호를 확인하면 돼요."

결선 검수:
"모호한 연결이 1개 남아 있습니다. 이것만 확인하면 최종 검증으로 갈 수 있어요."

Final 완료:
"회로 검증이 끝났습니다. 이제 조류계산에 필요한 계통 제원을 연결하면 됩니다."

반복적이고 방해되는 알림은 금지한다.

---

## 11. Agentic Competition Direction

대회에서 PowerLens를
단순한 YOLO 프로그램 또는 Chatbot으로 설명하지 않는다.

핵심 Agent loop:

Observe
→ Analyze
→ Decide
→ Act / Recommend
→ Verify
→ Human Escalation when needed
→ Re-verify

PowerLens의 Agentic AI는:

Vision,
Bus Mapping,
Connection Analysis,
Topology Validation,
Human Review,
Power Flow 준비

등 여러 도구와 상태를 연결하고 조율하는 역할을 강조한다.

정확한 표현:

"LLM이 단선도를 임의로 해석하는 시스템이 아니라,
Vision 및 전기적 검증 도구의 실제 결과를 Agent가 관찰하고
다음 분석 단계 또는 Human 검토 필요 여부를 판단하는 구조"

이다.

---

## 12. AI Architecture Principle

목표 구조:

Input Diagram
↓
YOLO / OpenCV / OCR
↓
Bus Mapping
↓
Connection Tracing
↓
Electrical / Topology Validation
↓
Structured Evidence + App State
↓
PowerLens Gemini Agent
↓
Proceed / Human Check / Block
↓
Human correction when required
↓
Re-validation
↓
Verified Circuit
↓
Parameters
↓
Power Flow
↓
Agent-assisted Result Explanation

---

## 13. Local Provider vs Gemini

LocalReviewAssistantProvider는
최종 자연어 AI의 주 두뇌가 아니다.

Local Provider의 주 역할:

- Gemini가 없을 때 fallback
- 현재 단계 표시
- blocker 표시
- deterministic next-step guidance
- 기본 상태 요약

Gemini Provider의 역할:

- 자연스러운 자유 대화
- PowerLens 상태 이해
- Evidence 기반 reasoning
- Workflow guidance
- 복합 질문 설명
- Agent orchestration

Gemini API 장애 또는 Key 부재가
핵심 PowerLens 기능 전체를 중단시키면 안 된다.

---

## 14. Security

GEMINI_API_KEY 및 기타 Secret은
절대로 Flutter/Web source에 넣지 않는다.

Secret은 Backend environment에서만 사용한다.

Browser bundle에서 API Key가 노출되어서는 안 된다.

---

## 15. PowerLens AI Visual Identity

AI 버튼/챗봇 UI도 제품의 중요한 UX 요소다.

기본 Chat Icon 하나를 임시로 놓고 끝내지 않는다.

PowerLens 브랜드와
전력/회로/AI 이미지를 결합한
친근하고 식별 가능한 AI Assistant Icon/Floating Button을 사용한다.

ChatGPT 등 다른 서비스의 캐릭터/아이콘을 그대로 복제하지 않는다.

Desktop:
Floating / Overlay Chat

Mobile:
Bottom Sheet / Full-width Chat

구조를 우선한다.

---

## 16. Web Adaptive Rule

Desktop layout을 단순 축소하여
Mobile에서 사용하는 것은 금지한다.

Desktop:
- Canvas
- Tool palette
- Inspector
- AI overlay

Mobile:
- 최대 Canvas 확보
- Inspector는 Bottom Sheet
- 적절한 Bottom Action
- AI는 Mobile Chat Sheet

등 Adaptive Layout을 사용한다.

---

## 17. Phone Photo Direction

향후 동일 Web App에서:

Mobile browser
→ Camera capture
→ Photo normalization
→ Existing Vision pipeline

흐름을 지원한다.

Photo normalization 대상:

- Document crop
- Perspective correction
- Rotation/skew
- Shadow/illumination normalization
- Noise/blur handling
- Line preservation

실제 손그림 지원 여부는
실제 사용자 사진으로 검증한 뒤 결정한다.

검증 없이 인식 성공을 주장하지 않는다.

---

## 18. User Evidence Request Rule

개발 과정에서 실제 사용자 입력이 필요하면
명확하게 별도로 요청해야 한다.

예:

[USER INPUT NEEDED]
- 실제 손그림 회로도 사진 5장
- 휴대폰 촬영 디지털 도면 사진 5장

필요하기 전에는 불필요한 데이터 생성을 사용자에게 요구하지 않는다.

---

## 19. User Web Verification Rule

Automated test만으로 실제 UX가 좋다고 판단하지 않는다.

사용자가 실제 Browser에서 확인해야 하는 시점에는:

[USER WEB CHECK NEEDED]

형태로 명확하게 알린다.

확인할 화면과 행동을 구체적으로 알려준다.

---

## 20. Engineering Safety

기존 기능을 보호한다.

- Vision
- Object Review
- Bus Mapping
- Connection Review
- Topology Validation
- Verified circuit
- Excel mapping
- CAD
- Power Flow

기존 동작을 임의로 다시 설계하지 않는다.

큰 변경 전에 현재 Source를 먼저 확인한다.

테스트하지 않은 내용을
"정상 동작"이라고 보고하지 않는다.

---

## 21. Development Rule

모든 향후 PowerLens 작업을 시작하기 전에
반드시 이 문서를 먼저 읽는다.

POWERLENS_AGENT_RULES.md

사용자 요청과 이 문서가 충돌하지 않는 한
이 문서를 Project Source of Truth로 사용한다.

각 작업의 최종 보고에는 필요 시:

- 어떤 PowerLens rule을 적용했는지
- 어떤 rule과 관련된 변경인지

를 명시한다.

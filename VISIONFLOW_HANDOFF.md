# VisionFlow Review Pipeline Handoff

전력계통 단선도(SLD) 자동 디지털화 및 **3단계 검수 파이프라인 (Agentic SLD Review Pipeline)** 가이드 문서입니다.  
본 브랜치를 checkout한 뒤 아래 절차에 따라 즉시 로컬 실행 및 추가 개발을 진행할 수 있습니다.

---

## 1. Pipeline Overview & Current Flow

```text
도면 이미지 업로드 (Drag & Drop / Gallery)
  ↓
[Step 1] 객체 검수 (Object Review)
  • YOLO + OpenCV 하이브리드 검출 (모선/발전기/부하/변압기)
  • 고유 번호 및 도면 텍스트 기반 Display Label 부여 (BUS 1, GEN 1, LOAD 1, TRANS 1)
  • Local Review Assistant가 우선 검토 항목(의심/누락) Proactive 브리핑
  • 정상 객체 일괄 승인 + 의심 객체 수정 + 드래그 가능한 라벨 & Leader Line
  ↓
[Step 2] 도면 전체 누락 검토 (Completeness Review)
  • 고밀도/복잡 영역 미검출 설비(OPEN) 확인 & 해소
  • Human Completeness Confirmation 체크
  ↓
[Gate 1] OBJECT VERIFIED Gate
  • 조건: 미해결 의심 객체 = 0, 미해결 누락 후보 = 0, Completeness 체크 = true
  ↓
[Step 3] 결선 검수 (Connection Review)
  • 확정된 객체 기반 A* 전기적 선로 탐색 및 Display Name 부여 (L1 (BUS 1 ↔ LOAD 1))
  • 그래프 유효성 검증 (발전기-부하 직결 위반, 고립 기기 등 실시간 진단)
  • 선로 선택 시 Glow Pulse 강조 + 비선택 선로 Dimming
  • 정상 결선 일괄 승인 / 결함 선로 재지정
  ↓
[Gate 2] Final Connection Gate
  • 조건: Critical Graph Issue = 0, 미해결 Ambiguous Line = 0
  ↓
[VerifiedSLD] 100% 무결한 전기 토폴로지 데이터 생성
  ↓
[Handoff] Flutter Canvas (전력계통 무한 캔버스 편집기 및 조류계산 시뮬레이터)
```

---

## 2. Quick Start

### A. Backend 실행 (FastAPI + YOLO Engine)

```bash
# 루트 디렉토리에서 실행:
py -3.13 -m uvicorn backend_api.main_server:app --host 127.0.0.1 --port 8000 --reload
# 또는:
cd backend_api
uvicorn main_server:app --host 127.0.0.1 --port 8000 --reload
```

### B. Frontend 실행 (Flutter Web)

```bash
cd frontend_app
flutter pub get
flutter run -d chrome --web-port=5000
```

---

## 3. URLs & Service Endpoints

* **Backend API URL**: http://127.0.0.1:8000
* **Backend API Docs (Swagger)**: http://127.0.0.1:8000/docs
* **Flutter Web App**: http://localhost:5000
* **Review Page Direct Route**: http://localhost:5000/#/ *(상단 🔍 AI 도면 검수 (SLD Review) 버튼 클릭)*

---

## 4. AI Provider Configuration

### 기본 모드 (Default: Local Review Assistant)
* **비용 0원, 외부 API Key 불필요**
* 휴리스틱 및 토폴로지 엔진 기반으로 완벽한 근거 설명, 우선순위 브리핑, 질의응답을 제공합니다.
* 환경변수 설정 없이 바로 실행 시 자동으로 `AI_PROVIDER=local`로 동작합니다.

### 향후 OpenAI 모드 확장 (Optional Future Extension)
```bash
# 선택 사항 (필요 시에만 설정):
export AI_PROVIDER=openai
export OPENAI_API_KEY="your-api-key-here"
```
*(OpenAI API Key가 없거나 유효하지 않아도 자동으로 Local Provider로 안전하게 fallback됩니다.)*

---

## 5. Main Backend APIs

| Endpoint | Method | Description |
| :--- | :---: | :--- |
| `/review/detect_objects` | `POST` | 이미지 1차 객체 검출 + Display Label 부여 + Proactive Summary 생성 |
| `/review/image/{document_id}` | `GET` | 세션 이미지 원본 조회 |
| `/review/proactive_summary` | `POST` | 현재 검수 단계의 우선순위 액션 아이템 요약 생성 |
| `/review/agent_chat` | `POST` | 선택 객체/선로/도면 기반 AI 어시스턴트 질의응답 |
| `/review/check_completeness` | `POST` | 도면 전체 누락 설비(Missing Candidates) 검출 |
| `/review/verify_objects_gate` | `POST` | Object Gate 검증 (통과 시 OBJECT_VERIFIED 반환) |
| `/review/detect_connections` | `POST` | 확정 노드 기반 선로 인식 및 Line Display Label 부여 |
| `/review/validate_topology` | `POST` | 실시간 계통 토폴로지/전기적 규칙 무결성 검증 |
| `/review/agent_review_connection`| `POST` | 결선 이상 항목 근거 설명 및 원인 분석 |
| `/review/verify_final_gate` | `POST` | Final Gate 검증 및 `VerifiedSLD` 생성 |
| `/analyze_image` | `POST` | (Legacy) 원샷 캔버스 직행 변환 엔드포인트 |
| `/run_simulation` | `POST` | 계통 조류계산 시뮬레이션 실행 엔드포인트 |

---

## 6. Test Suites & Verification

### Backend Tests
```bash
# 71개 유닛/회귀 테스트 전체 실행 (루트 디렉토리)
python -m unittest discover -s backend_api/tests -p "test_*.py" -v
```

### Frontend Tests & Analysis
```bash
cd frontend_app

# 프론트엔드 유닛/위젯 테스트
flutter test

# 정적 분석 (0 Error, 0 Warning)
flutter analyze
```

---

## 7. Key Architecture Notes

1. **내부 불변 ID vs 사용자 표시명 분리**:
   * 내부 ID: `bus_0`, `load_22`, `line_0` (그래프 연산 및 조류계산 무결성 보존)
   * 표시명: `BUS 4`, `LOAD 1`, `L1 (BUS 4 ↔ LOAD 1)` (UI 및 사용자 상호작용 레이어)
2. **Draggable Labels + Leader Lines**:
   * 복잡한 배선이 가려지는 문제를 방지하기 위해 사용자가 라벨을 자유롭게 드래그 가능하며, 원래 심볼과의 연결 관계는 가느다란 가이드선(`Leader Line`)으로 보존됩니다.
3. **VerifiedSLD Source of Truth**:
   * 사람의 승인과 전기적 규칙 검증을 완벽히 통과한 `VerifiedSLD` 구조체만 Flutter Canvas로 안전하게 Handoff됩니다.

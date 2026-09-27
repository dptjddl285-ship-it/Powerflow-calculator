# PowerLens 현재 상태 인수인계 — 2026-09-27

## 저장소와 브랜치

- 개발 mirror: `hpo200222-rgb/my-powersimulator` (`main`)
- 팀 원본: `dptjddl285-ship-it/Powerflow-calculator` (`master`)
- 인수인계 브랜치: `handoff/powerlens-current-20260927`
- 이 문서를 추가하기 직전의 소스 스냅샷 HEAD: `35bccc4771d5c8bb53781b5cab103dd271a7ad67`
- mirror 기준 SHA 확인값: `35bccc4771d5c8bb53781b5cab103dd271a7ad67`
- 팀 원본 `master` 확인값: `0c38072db520dce3d3a97e4e3157598c56239ef3`

이 문서는 소스 스냅샷에 문서만 추가하는 인수인계입니다. 문서 추가 후 만들어지는 최종 commit SHA는 Git 이력과 전달 보고에서 확인하세요. 팀 원본 `master`에는 직접 push/merge하지 말고, 인수인계 브랜치만 사용합니다.

### 친구가 받는 방법

이미 원본 저장소를 clone한 경우:

```bash
git fetch origin
git switch handoff/powerlens-current-20260927
git pull
```

처음 받는 경우:

```bash
git clone https://github.com/dptjddl285-ship-it/Powerflow-calculator.git
cd Powerflow-calculator
git fetch origin
git switch handoff/powerlens-current-20260927
```

브랜치 전환 후 `git status`와 `git log -n 5 --oneline`으로 받은 상태를 확인하세요.

## 실행 환경

- Python 3.11+
- Flutter Web
- Google Chrome 또는 Chromium 계열 브라우저
- Gemini 기능을 쓰려면 개인 로컬 `.env`에 API Key 설정 필요
- `.env`, API Key, 기타 secret은 저장소에 포함하지 않습니다.

의존성 설치:

```bash
pip install -r backend_api/requirements.txt
```

Windows 권장 실행:

```bat
run_powerlens.bat
```

또는:

```bash
python run_powerlens.py
```

개별 실행 시 백엔드는 `http://127.0.0.1:8000` (Swagger `/docs`), 프론트는 `http://127.0.0.1:58640`을 사용합니다. 정적 프론트를 직접 빌드/실행할 때:

```bash
cd frontend_app
flutter pub get
flutter build web
cd ..
python -m http.server 58640 --directory frontend_app/build/web
```

## 전체 흐름과 핵심 원칙

```text
도면 이미지
→ 객체 검수
→ 모선 번호 매핑
→ 결선 검수
→ deterministic Final Validation
→ VerifiedSLD
→ Excel 대조/바인딩
→ Flutter CAD
→ AC Newton-Raphson
→ 결과 분석
```

- Vision/OCR/Gemini는 evidence를 제공합니다.
- Deterministic validator와 사람의 명시적 확인 Gate가 workflow 상태를 확정합니다.
- Newton-Raphson solver가 수치 결과를 계산합니다.
- AI가 topology, Bus 번호, Excel parameter, PF result를 임의 생성하거나 Gate를 우회하면 안 됩니다.
- 판독이 불명확하면 `UNCERTAIN` 또는 blocker로 남기고 사용자가 확인합니다.

## 객체 검수

대상 분류는 Bus, Load, Generator, Transformer입니다.

- 누락 후보를 먼저 처리한 뒤 suspicious object를 개별 검토하고 정상 객체 종류를 확인합니다.
- 정상 객체 확인 순서: `Bus → Load → Generator → Transformer`.
- 의심 객체는 Inspector 카드 외곽을 강조하며 `[맞음]` 또는 `[수정]`으로 사용자가 판정합니다.
- 카테고리 오른쪽 진행은 확인 후 다음 종류로 이동하고, 왼쪽은 이전 종류를 재확인합니다. Badge 선택은 보기/이동만 하며 완료 상태를 자동 생성하지 않습니다.
- 전체 도면 보기는 summary이며 다섯 번째 검수 종류가 아닙니다.
- 모든 필수 종류 확인, missing/suspicious 해소, deterministic gate 재확인, blocker 0이어야 `[객체 검수 완료]` CTA가 준비됩니다.
- CTA 준비와 사람의 최종 확인만 남은 상태에서 Lensy는 success/green으로 바뀝니다. 마지막 전체 도면 확인 후 사용자가 CTA를 눌러야 합니다.

## Bus Mapping

- 실제 검출된 Bus crop을 대상으로 Gemini Vision 판독을 수행합니다.
- 유효하고 고유한 정수는 `VERIFIED`; null/invalid/duplicate/불명확은 `UNCERTAIN`으로 처리합니다.
- 누락 번호를 1..N으로 채우거나 특정 24-bus 번호를 production에 하드코딩하지 않습니다.
- 판독 중 Lensy는 thinking, unresolved/duplicate/blocker가 남으면 warning입니다.
- 모든 번호가 기술적으로 유효하고 Bus Gate blocker가 없으며 사용자의 확인이 대기 중일 때 Lensy는 success/green입니다.
- AI 판독 성공만으로 Connection Review로 자동 이동하지 않습니다. 사용자가 도면 번호를 다시 확인하고 `[모선 검수 완료]`를 누르거나 Lensy에게 “다 했어/확인했어”라고 말한 뒤 Bus Gate를 거칩니다.
- Bus 본체는 tight blue outline, 라벨은 blue, Bus와 라벨을 잇는 leader는 검정 dashed line입니다.

## Connection Review

선로 색상 의미:

- 현재 검토 선로: cyan/aqua 형광
- 이미 확인한 visited 선로: 불투명 진한 orange `#FF6D00`
- 미확인 선로: 원본 도면색
- Bus endpoint: blue `#2563EB`
- Generator/Load/Transformer endpoint: gold `#EAB308`
- 우선순위: `CURRENT > VISITED > ORIGINAL`

오른쪽 이동은 현재 선로를 visited로 기록하고 다음 선로를 current로 지정합니다. 왼쪽 이동은 이력도 한 단계 되감아 복귀 선로를 current로, 이후 선로는 미확인 상태로 돌립니다. Blocker가 없고 visual sweep이 끝난 뒤 Lensy가 success/green 및 마지막 확인 안내를 표시합니다. `[결선 검수 완료]`는 사용자가 직접 눌러야 합니다. Topology/gate 판단과 line order는 색상 표시와 분리해 유지합니다.

## Lensy 대화와 단계 상태

- 현재 단계 canonical guidance와 대화 history를 분리합니다. 이전 안내는 history에 한 번만 보존하고, 동일 문구 rebuild 시 중복 저장하지 않습니다.
- 새 도면 또는 검수 처음으로를 선택하면 history는 보존하고 단계별 live guidance, highlight/focus, processing 및 stale 상태를 초기화합니다.
- 세션 경계 안내:
  - `──────── 검수를 처음부터 다시 시작합니다 ────────`
  - `──────── 새 도면 검수를 시작합니다 ────────`
- Lensy 상태 의미: idle/blue는 일반 검수, thinking은 분석 중, warning은 해결할 항목 존재, success/green은 기술적 준비가 끝나고 사용자 최종 확인만 남은 상태입니다.
- 닫힌 말풍선과 열린 대화 tail은 같은 단계의 READY 메시지를 사용해야 합니다.

## Excel / Transformer 규칙

- Transformer lead line은 topology evidence이며 solver electrical branch 자체가 아닙니다.
- Transformer branch는 실제 connected buses와 실제 Excel transformer row를 근거로 구성합니다. `nC2` 조합으로 branch를 추정하지 않습니다.
- Excel로 Bus/Line/Transformer를 자동 생성하지 않습니다.
- Excel에만 있는 Generator/Load는 repair proposal로 제안할 수 있지만, 명시적 Apply 전에는 canvas/solver를 변경하지 않습니다. Reject 시 원본을 유지합니다.
- 특정 Bus 번호만으로 synchronous condenser 등 설비 역할을 추정하지 않습니다.

## Golden QA와 일반화 한계

기준 샘플은 `default/검사사진.jpg`와 `default/case24_psse.xlsx`입니다. Golden QA oracle은 Bus 24, Generator 11, Branch 34 unique, Transformer pair 6, Sbase 100, Slack Bus 1이며 production hardcode가 아닙니다.

코드는 실제 검출 수를 사용하며 특정 24-bus 도면 전용이 아닙니다. 그렇더라도 모든 회로도에서 100% 동작을 보장하지 않습니다. 다른 Bus 수/해상도/심볼 크기/라벨 위치/번호 배치, Transformer가 없거나 여러 개인 SLD로 일반화 검증이 더 필요합니다. 향후 점검 항목에는 Bus 번호 범위 정책, API response ID mismatch 시 index fallback, 다양한 심볼 스타일에 대한 CV/YOLO 강건성이 있습니다.

## 전달 시 검증 및 보안

- 최근 focused Flutter 검증: ReviewCoachPolicy, Object Visual Sweep, Object Review guidance widget, Bus Mapping Human Review Gate 관련 45 tests passed.
- 최근 Flutter web build 성공, `git diff --check` 통과.
- 전체 E2E나 브라우저 자동화는 이번 인수인계 전달에서 실행하지 않았습니다.
- Backend full suite는 이번 전달에서 실행하지 않았습니다. 과거에는 환경의 `httpx`/`TestClient` 호환 문제로 collection 단계가 중단된 이력이 있으므로 full PASS로 기록하지 않습니다.
- API Key는 저장소/인수인계 문서에 포함하지 않습니다. 대화 등에 노출된 Key가 있다면 재발급/교체하세요.
- `scratch/`, `e2e_evidence/`, `.env`, screenshot 및 secret은 인수인계 commit에 포함하지 않습니다.
- `master` 직접 push/merge, reset/clean, stash drop, force push는 금지합니다.

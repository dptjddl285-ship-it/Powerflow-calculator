# PowerLens 젤최신버전

Flutter 화면부터 FastAPI, YOLO/OpenCV 객체 인식, 실제 픽셀 기반 선로 추적까지 연결된 에이전트 추가 전 전체 실행 버전입니다.

## 포함 범위

- Flutter 앱 전체 소스와 플랫폼 프로젝트
- FastAPI `/analyze_image`, `/upload_excel`, `/run_simulation` API
- Bus, Load, Generator, Transformer 하이브리드 검출
- 실제 source-pixel 기반 전기 토폴로지 추적
- 이미지 품질 적응형 파이프라인과 그래프 검증 정책
- 기본 모델 `2026_07_30_coslr.pt`
- 백엔드 회귀 테스트

## 제외 범위

- Agent/LLM 후보 검토 기능
- 진단, 비교, 일회성 추론 스크립트
- 학습 데이터와 학습 산출물
- 캐시와 임시 결과 이미지
- 사용하지 않는 구형 모델

## 실행

```powershell
cd backend_api
python -m pip install -r requirements.txt
.\start_server.ps1
```

다른 터미널에서 Flutter 앱을 실행합니다.

```powershell
cd frontend_app
flutter pub get
flutter run -d windows
```

현재 `/run_simulation`은 UI 연동 상태를 유지하는 프로토타입 응답이며 실제 조류계산은 구현 대상에서 제외되어 있습니다.

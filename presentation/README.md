# 🏛️ PowerLens Web Presentation (3분 압축 발표자료)

PowerLens의 핵심 아키텍처와 Agentic AI 워크플로우를 심사위원에게 3분 안에 직관적으로 설명하기 위해 제작된 독립형 웹 프레젠테이션 덱입니다.

---

## 🚀 빠른 실행 방법

### 1. 로컬 브라우저에서 바로 열기 (인터넷 불필요)
* `presentation/index.html` 파일을 더블 클릭하여 Chrome/Edge 등의 브라우저에서 바로 엽니다.
* 외부 CDN 의존 없이 모든 핵심 그래픽 에셋이 `assets/` 디렉터리에 포함되어 있어 완벽히 오프라인 구동됩니다.

### 2. 로컬 웹 서버로 열기 (권장)
```bash
# PowerLens 저장소 루트에서 실행:
python -m http.server 3000 --directory presentation
```
브라우저에서 `http://localhost:3000` 접속.

### 3. Vercel 배포 방법
* Vercel 대시보드에서 Git 저장소 연동 시 **Root Directory**를 `presentation`으로 지정하면 추가 빌드 설정 없이 즉시 글로벌 정적 호스팅됩니다.
* 또는 Vercel CLI 이용:
  ```bash
  cd presentation
  npx vercel --prod
  ```

---

## ⌨️ 키보드 네비게이션 가이드

| 단축키 | 동작 설명 |
| :--- | :--- |
| `→` / `Space` / `PageDown` | 다음 씬으로 이동 |
| `←` / `PageUp` | 이전 씬으로 이동 |
| `1` ~ `5` | 해당 번호의 씬으로 즉시 점프 |
| `F` | 브라우저 전체화면 토글 (Full Screen) |
| `I` | 슬라이드 인덱스 패널 열기/닫기 (Index) |
| `S` | 발표자 스크립트 큐 노트 열기/닫기 (Script) |
| `ESC` | 열린 인덱스/스크립트 드로어 닫기 |

---

## ⚙️ 라이브 시연 연동 설정 (`config.js`)

Scene 5의 **[LIVE DEMO ➔]** 버튼이 가리키는 대상 주소는 `presentation/config.js`의 `appUrl`에서 변경할 수 있습니다.
또한 브라우저 쿼리 파라미터를 통해 동적으로 덮어쓸 수 있습니다:
```
http://localhost:3000/?app=http://localhost:8000
```

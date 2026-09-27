/**
 * PowerLens Web Presentation Configuration
 * 
 * Local presentation & Vercel deployment compatible.
 * External dependency-free.
 */
window.POWERLENS_PRESENTATION_CONFIG = {
  // Target URL for launching the actual PowerLens application during Live Demo.
  // Can be overridden via URL query parameter: ?app=http://...
  appUrl: (function () {
    const params = new URLSearchParams(window.location.search);
    return params.get("app") || "http://localhost:8000";
  })(),

  // Presentation metadata
  title: "PowerLens / Product Architecture & Live Demo",
  totalScenes: 5,
  presentationDuration: "03:00",
  demoDuration: "07:00",

  // Scene definitions for Index & Navigation
  scenes: [
    {
      index: 1,
      act: "INTRODUCTION",
      title: "단선도에서 조류계산까지의 브릿지",
      duration: "0:15",
      id: "scene-1"
    },
    {
      index: 2,
      act: "PROBLEM DEFINITION",
      title: "왜 단순 OCR이 아닌 상호 검증인가?",
      duration: "0:35",
      id: "scene-2"
    },
    {
      index: 3,
      act: "SYSTEM ARCHITECTURE",
      title: "전체 시스템 아키텍처 및 파이프라인",
      duration: "1:00",
      id: "scene-3"
    },
    {
      index: 4,
      act: "AGENTIC REVIEW",
      title: "결정론적 검수 에이전트와 도구 루프",
      duration: "0:50",
      id: "scene-4"
    },
    {
      index: 5,
      act: "PROOF & LIVE DEMO",
      title: "정량 검증 지표 및 라이브 시연 전환",
      duration: "0:20",
      id: "scene-5"
    }
  ]
};

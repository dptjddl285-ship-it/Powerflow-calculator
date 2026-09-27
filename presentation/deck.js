/**
 * PowerLens Presentation Engine - Minimal Clean Edition
 * Zero external library dependencies. Fast, clean, reliable.
 */
(function () {
  "use strict";

  const config = window.POWERLENS_PRESENTATION_CONFIG || {
    totalScenes: 5,
    scenes: []
  };

  let current = 1;
  const scenes = document.querySelectorAll(".scene");
  const currentNumber = document.getElementById("currentNumber");
  const prevBtn = document.getElementById("prevBtn");
  const nextBtn = document.getElementById("nextBtn");
  const curtain = document.getElementById("curtain");
  const indexDrawer = document.getElementById("indexDrawer");
  const scriptDrawer = document.getElementById("scriptDrawer");
  const currentScriptText = document.getElementById("currentScriptText");

  // Presenter spoken scripts per scene
  const presenterScripts = {
    1: "PowerLens는 비정형 단선도 이미지 한 장으로부터 공학적으로 검수 가능한 계통 모델을 복원하고, 정밀 AC 조류계산까지 단절 없이 연결하는 전력계통 분석 시스템입니다.",
    2: "전력 계통 전산화의 병목은 단순 텍스트 인식이 아닙니다. 시각적 단선도와 수치 엑셀 데이터 사이에는 불일치가 발생할 수 있으며, 연결 또는 파라미터 오류는 비수렴이나 잘못된 결과로 이어질 수 있습니다. PowerLens는 이 시각 도면과 구조화 데이터를 상호 교차 검증하도록 설계되었습니다.",
    3: "PowerLens의 파이프라인은 두 갈래로 시작합니다. 단선도 이미지에서 컴포넌트와 연결 위상을 추출하고, 계통 엑셀에서 물리적 전기 파라미터를 파싱합니다. 중앙의 교차 검증 모듈이 도면과 엑셀 간의 누락·초과 설비를 대조하고, 이상 감지 시 AI 에이전트와 사용자 검수를 거쳐 검증된 계통 모델로 합성된 후 정밀 AC 뉴턴-랩슨 솔버로 전달됩니다.",
    4: "PowerLens의 에이전트는 환각이나 임의 수정을 허용하지 않습니다. 결선 이상이 감지되면 결정론적 플래너가 등록된 전용 비전 도구를 실행하고, 점수 개선 여부를 엄격히 평가한 뒤, 오직 엔지니어의 명시적 승인을 거쳐서만 도면에 반영합니다. 대화형 Gemini Lensy는 이 과정에서 도면을 건드리지 않고 원인 분석과 가이던스만 독립적으로 제공합니다.",
    5: "PowerLens는 객체 검출 F1 98.01%, 136개 백엔드 회귀 테스트를 통해 파이프라인의 무결성을 입증했습니다. 이제 실제 단선도를 올리고 에이전트 검수를 거쳐 전력 조류가 계산되는 전 과정을 라이브 시연으로 보여드리겠습니다."
  };

  function updateChrome(idx) {
    if (currentNumber) {
      currentNumber.textContent = String(idx).padStart(2, "0");
    }

    if (prevBtn) {
      prevBtn.disabled = (idx <= 1);
    }
    if (nextBtn) {
      nextBtn.disabled = (idx >= config.totalScenes);
    }

    // Update Index active states if present
    document.querySelectorAll(".index-item-btn").forEach(function (btn, i) {
      btn.classList.toggle("active", i + 1 === idx);
    });

    // Update Script Drawer text if present
    if (currentScriptText) {
      currentScriptText.textContent = presenterScripts[idx] || "";
    }
  }

  function goToScene(idx, skipCurtain, direction) {
    if (idx < 1 || idx > config.totalScenes || (idx === current && !skipCurtain)) return;

    current = idx;
    scenes.forEach(function (el, i) {
      el.classList.toggle("active", i + 1 === current);
    });
    updateChrome(current);
    history.replaceState(null, "", "#slide-" + current);

    if (window.PowerLensAnimations) {
      if (direction === 'backward') {
        window.PowerLensAnimations.showFinalState(current);
      } else {
        window.PowerLensAnimations.onSceneEnter(current, 'forward');
      }
    }
  }

  // =========================================================================
  // PRESENTATION STEP NAVIGATION (Keyboard Control)
  // =========================================================================
  function advancePresentationStep() {
    // If the animation controller has a pending step in current scene, execute it first
    if (window.PowerLensAnimations && window.PowerLensAnimations.stepForward(current)) {
      return;
    }

    // If at the end of the scene's animation steps, proceed to the next scene (intro state)
    if (current < config.totalScenes) {
      goToScene(current + 1, false, 'forward');
    }
  }

  function goBackPresentationStep() {
    // If the animation controller can step backward in current scene, do so
    if (window.PowerLensAnimations && window.PowerLensAnimations.stepBackward(current)) {
      return;
    }

    // If at step 0, proceed to previous scene in its completed final state
    if (current > 1) {
      goToScene(current - 1, false, 'backward');
    }
  }

  // =========================================================================
  // SLIDE-LEVEL DIRECT NAVIGATION (Button Control with 300ms Debounce Lock)
  // =========================================================================
  let isNavigating = false;
  const NAV_LOCK_MS = 300;

  function goToNextSceneDirect() {
    if (isNavigating) return;
    if (current >= config.totalScenes) return;

    isNavigating = true;
    setTimeout(function () {
      isNavigating = false;
    }, NAV_LOCK_MS);

    // Stop and clean up any running animations/timers
    if (window.PowerLensAnimations) {
      window.PowerLensAnimations.cleanup();
    }

    goToScene(current + 1, false, 'forward');
  }

  function goToPreviousSceneDirect() {
    if (isNavigating) return;
    if (current <= 1) return;

    isNavigating = true;
    setTimeout(function () {
      isNavigating = false;
    }, NAV_LOCK_MS);

    // Stop and clean up any running animations/timers
    if (window.PowerLensAnimations) {
      window.PowerLensAnimations.cleanup();
    }

    // Direct backward entry always displays the target scene in its complete final state
    goToScene(current - 1, false, 'backward');
  }

  function toggleFullscreen() {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen().catch(function () {});
    } else {
      if (document.exitFullscreen) {
        document.exitFullscreen().catch(function () {});
      }
    }
  }

  function toggleIndex(open) {
    if (!indexDrawer) return;
    if (typeof open === "boolean") {
      indexDrawer.classList.toggle("open", open);
    } else {
      indexDrawer.classList.toggle("open");
    }
    if (indexDrawer.classList.contains("open") && scriptDrawer) {
      scriptDrawer.classList.remove("open");
    }
  }

  function toggleScript(open) {
    if (!scriptDrawer) return;
    if (typeof open === "boolean") {
      scriptDrawer.classList.toggle("open", open);
    } else {
      scriptDrawer.classList.toggle("open");
    }
    if (scriptDrawer.classList.contains("open") && indexDrawer) {
      indexDrawer.classList.remove("open");
    }
  }

  function closeAllDrawers() {
    if (indexDrawer) indexDrawer.classList.remove("open");
    if (scriptDrawer) scriptDrawer.classList.remove("open");
  }

  function parseHash() {
    const match = window.location.hash.match(/slide-(\d+)/i);
    if (match) {
      const idx = parseInt(match[1], 10);
      if (idx >= 1 && idx <= config.totalScenes) {
        return idx;
      }
    }
    return 1;
  }

  // Keyboard navigation: step control
  window.addEventListener("keydown", function (e) {
    if (e.target && (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA")) return;

    if (e.key === "ArrowRight" || e.key === " " || e.key === "PageDown") {
      e.preventDefault();
      advancePresentationStep();
    } else if (e.key === "ArrowLeft" || e.key === "PageUp") {
      e.preventDefault();
      goBackPresentationStep();
    } else if (e.key === "f" || e.key === "F") {
      e.preventDefault();
      toggleFullscreen();
    } else if (e.key === "i" || e.key === "I") {
      e.preventDefault();
      toggleIndex();
    } else if (e.key === "s" || e.key === "S") {
      e.preventDefault();
      toggleScript();
    } else if (e.key === "Escape") {
      closeAllDrawers();
    } else if (e.key >= "1" && e.key <= String(config.totalScenes)) {
      goToScene(parseInt(e.key, 10), false, 'forward');
    }
  });

  // Persistent Deck Buttons: slide-level direct navigation
  if (prevBtn) {
    prevBtn.addEventListener("click", function (e) {
      e.preventDefault();
      goToPreviousSceneDirect();
    });
  }

  if (nextBtn) {
    nextBtn.addEventListener("click", function (e) {
      e.preventDefault();
      goToNextSceneDirect();
    });
  }

  document.querySelectorAll(".drawer-close").forEach(function (btn) {
    btn.addEventListener("click", closeAllDrawers);
  });

  // Build index items if indexList is present
  const indexList = document.getElementById("indexList");
  if (indexList && config.scenes) {
    config.scenes.forEach(function (s) {
      const item = document.createElement("button");
      item.type = "button";
      item.className = "index-item-btn";
      item.innerHTML = `
        <div>
          <div style="font-family: var(--font-mono); font-size: 10px; color: var(--c-blue); font-weight: 700;">${s.act}</div>
          <div style="font-size: 13px; font-weight: 700; color: var(--text-title); margin-top: 2px;">${s.title}</div>
        </div>
        <span style="font-family: var(--font-mono); font-size: 11px; color: var(--text-muted);">${s.duration}</span>
      `;
      item.addEventListener("click", function () {
        goToScene(s.index, false, 'forward');
        closeAllDrawers();
      });
      indexList.appendChild(item);
    });
  }

  // Live Demo Button Launch Handler
  const launchDemoBtn = document.getElementById("launchDemoBtn");
  if (launchDemoBtn) {
    launchDemoBtn.addEventListener("click", function () {
      const targetUrl = config.appUrl;
      window.open(targetUrl, "_blank");
    });
  }

  // Initial load
  const initialIdx = parseHash();
  goToScene(initialIdx, true, 'forward');

})();

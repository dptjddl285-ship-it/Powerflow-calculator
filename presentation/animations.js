/**
 * PowerLens Presentation Animation Orchestrator
 * Pure engineering animation system powered by local anime.js v3.2.2.
 * Focuses audience attention according to presenter's spoken narrative:
 * Active: 1.0 (emphasized), Completed: 0.70~0.85, Inactive: 0.25~0.35.
 */
(function (root, factory) {
  if (typeof define === 'function' && define.amd) {
    define([], factory);
  } else if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.PowerLensAnimations = factory();
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const anime = window.anime;
  const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Track current step for each scene
  const stepState = {
    1: 0,
    2: 0,
    3: 0,
    4: 0,
    5: 0,
  };

  const maxSteps = {
    1: 0, // Intro auto-plays once
    2: 5, // 5 bottleneck & takeaway steps
    3: 7, // 7 architecture pipeline steps
    4: 7, // 7 agentic review loop steps
    5: 0, // Metric cards auto-play once
  };

  // Track active timeouts for clean cancellation
  const activeTimeouts = new Set();

  function safeTimeout(fn, delay) {
    const id = setTimeout(function () {
      activeTimeouts.delete(id);
      fn();
    }, delay);
    activeTimeouts.add(id);
    return id;
  }

  function clearAllTimeouts() {
    activeTimeouts.forEach(function (id) {
      clearTimeout(id);
    });
    activeTimeouts.clear();
  }

  // Cancel and clean up all running animations and timers across all scenes
  function cleanup() {
    clearAllTimeouts();

    if (anime) {
      const allSelectors = [
        '#scene-1 .s1-blueprint-frame',
        '#scene-1 .s1-wordmark',
        '#scene-1 .s1-accent-rule',
        '#scene-1 .s1-subtitle',
        '#scene-1 .s1-meta-box',
        '#s2-process-bar',
        '#s2-process-bar .s2-step-node',
        '#s2-process-bar .s2-step-arrow',
        '#s2-card-1',
        '#s2-card-2',
        '#s2-card-3',
        '#s2-bottom-banner',
        '#scene-3-svg .s3-elem',
        '#scene-3-svg .s3-path',
        '#scene-4-svg .s4-elem',
        '#scene-4-svg .s4-path',
        '#s4-tools-legend',
        '#s4-lensy-legend',
        '#s4-btn-apply',
        '#s5-card-1',
        '#s5-card-2',
        '#s5-card-3',
        '#s5-demo-banner',
        '#launchDemoBtn'
      ];
      allSelectors.forEach(function (sel) {
        try {
          const matched = qa(sel);
          if (matched.length > 0) {
            anime.remove(matched);
          }
        } catch (e) {}
      });
    }
  }

  // Helper: DOM lookup
  function el(id) {
    return document.getElementById(id);
  }

  function q(selector, parent) {
    return (parent || document).querySelector(selector);
  }

  function qa(selector, parent) {
    return Array.from((parent || document).querySelectorAll(selector));
  }

  // Set opacity directly or via anime
  function setOpacity(targets, opacity, duration, delay) {
    if (!targets) return;
    if (prefersReducedMotion || !anime || duration === 0) {
      if (Array.isArray(targets) || (typeof NodeList !== 'undefined' && targets instanceof NodeList)) {
        targets.forEach(function (t) { if (t) t.style.opacity = String(opacity); });
      } else {
        targets.style.opacity = String(opacity);
      }
      return;
    }
    anime.remove(targets);
    return anime({
      targets: targets,
      opacity: opacity,
      duration: duration || 280,
      delay: delay || 0,
      easing: 'easeOutQuad'
    });
  }

  // =========================================================================
  // SVG PATH DRAWING HELPERS
  // =========================================================================
  function preparePath(path) {
    if (!path) return 0;
    let length = 100;
    try {
      length = path.getTotalLength();
    } catch (e) {
      length = 100;
    }
    path.style.strokeDasharray = length;
    path.style.strokeDashoffset = length;

    if (!path.dataset) path.dataset = {};
    if (path.getAttribute && path.getAttribute('marker-end') && !path.dataset.originalMarker) {
      path.dataset.originalMarker = path.getAttribute('marker-end');
    }
    if (path.removeAttribute) {
      path.removeAttribute('marker-end');
    }
    path.style.opacity = '1';
    return length;
  }

  function drawPath(path, duration, delay) {
    if (!path) return Promise.resolve();
    if (prefersReducedMotion || !anime) {
      restorePath(path);
      return Promise.resolve();
    }

    const length = preparePath(path);
    const originalMarker = path.dataset ? path.dataset.originalMarker : null;

    return new Promise(function (resolve) {
      anime.remove(path);
      anime({
        targets: path,
        strokeDashoffset: [length, 0],
        duration: duration || 450,
        delay: delay || 0,
        easing: 'easeInOutQuad',
        update: function (anim) {
          if (originalMarker && anim.progress > 80 && path.getAttribute && !path.getAttribute('marker-end')) {
            if (path.setAttribute) path.setAttribute('marker-end', originalMarker);
          }
        },
        complete: function () {
          restorePath(path);
          resolve();
        }
      });
    });
  }

  function restorePath(path) {
    if (!path) return;
    path.style.strokeDashoffset = '';
    const isDashed = (path.dataset && path.dataset.isDashed === 'true') ||
      (path.getAttribute && path.getAttribute('stroke-dasharray') === '4,4');
    if (isDashed) {
      path.style.strokeDasharray = '4,4';
    } else {
      path.style.strokeDasharray = '';
    }
    if (path.dataset && path.dataset.originalMarker && path.setAttribute) {
      path.setAttribute('marker-end', path.dataset.originalMarker);
    }
    path.style.opacity = '1';
  }

  function dimPath(path, opacity) {
    if (!path) return;
    restorePath(path);
    path.style.opacity = String(opacity !== undefined ? opacity : 0.28);
  }

  // =========================================================================
  // SCENE 1: TITLE (Auto Sequence, <= 450ms total)
  // =========================================================================
  function playScene1Intro() {
    if (prefersReducedMotion || !anime) return;

    const frame = q('#scene-1 .s1-blueprint-frame');
    const wordmark = q('#scene-1 .s1-wordmark');
    const rule = q('#scene-1 .s1-accent-rule');
    const subtitle = q('#scene-1 .s1-subtitle');
    const meta = q('#scene-1 .s1-meta-box');

    // 1. Diagram reveals subtly (380ms)
    if (frame) {
      anime.remove(frame);
      anime({
        targets: frame,
        opacity: [0, 1],
        scale: [1.015, 1],
        duration: 380,
        easing: 'easeOutQuad'
      });
    }

    // 2. Title & accent (300ms, starts at 60ms)
    if (wordmark) {
      anime.remove(wordmark);
      anime({
        targets: wordmark,
        opacity: [0, 1],
        translateY: [10, 0],
        duration: 300,
        delay: 60,
        easing: 'easeOutQuad'
      });
    }

    if (rule) {
      anime.remove(rule);
      anime({
        targets: rule,
        scaleX: [0, 1],
        duration: 300,
        delay: 100,
        easing: 'easeOutQuad'
      });
    }

    // 3. Subtitle (260ms, starts at 140ms -> finishes at 400ms)
    if (subtitle) {
      anime.remove(subtitle);
      anime({
        targets: subtitle,
        opacity: [0, 1],
        translateY: [6, 0],
        duration: 260,
        delay: 140,
        easing: 'easeOutQuad'
      });
    }

    // 4. Presenter meta (260ms, starts at 170ms -> finishes at 430ms)
    if (meta) {
      anime.remove(meta);
      anime({
        targets: meta,
        opacity: [0, 1],
        duration: 260,
        delay: 170,
        easing: 'easeOutQuad'
      });
    }
  }

  // =========================================================================
  // SCENE 2: PROBLEM DEFINITION (5 Steps)
  // =========================================================================
  const s2BadgeLabels = {
    0: 'STEP 0 / 5 · 개요',
    1: 'STEP 1 / 5 · 기존 수작업 공정 흐름',
    2: 'STEP 2 / 5 · 병목 1: 반복 수작업',
    3: 'STEP 3 / 5 · 병목 2: 도면 ↔ 데이터 불일치',
    4: 'STEP 4 / 5 · 병목 3: 검수 및 오류 추적 부담',
    5: 'STEP 5 / 5 · 핵심 결론: 상호 교차검증',
  };

  function updateScene2(step, direction) {
    const badge = el('s2-step-badge');
    if (badge) badge.textContent = s2BadgeLabels[step] || `STEP ${step} / 5`;

    const bar = el('s2-process-bar');
    const nodes = qa('#s2-process-bar .s2-step-node');
    const arrows = qa('#s2-process-bar .s2-step-arrow');
    const c1 = el('s2-card-1');
    const c2 = el('s2-card-2');
    const c3 = el('s2-card-3');
    const banner = el('s2-bottom-banner');

    if (step === 0) {
      setOpacity(bar, 0.35, 200);
      setOpacity(c1, 0.35, 200);
      setOpacity(c2, 0.35, 200);
      setOpacity(c3, 0.35, 200);
      setOpacity(banner, 0, 200);
      if (c1) c1.classList.remove('active');
      if (c2) c2.classList.remove('active');
      if (c3) c3.classList.remove('active');
    } else if (step === 1) {
      setOpacity(bar, 1.0, 250);
      setOpacity(c1, 0.35, 200);
      setOpacity(c2, 0.35, 200);
      setOpacity(c3, 0.35, 200);
      setOpacity(banner, 0, 200);

      if (!prefersReducedMotion && anime && direction === 'forward') {
        anime.remove(nodes);
        anime({
          targets: nodes,
          opacity: [0.25, 1],
          translateX: [8, 0],
          delay: anime.stagger(120),
          duration: 250,
          easing: 'easeOutQuad'
        });
        anime.remove(arrows);
        anime({
          targets: arrows,
          opacity: [0, 1],
          delay: anime.stagger(120, { start: 60 }),
          duration: 200,
          easing: 'easeOutQuad'
        });
      } else {
        nodes.forEach(function (n) { n.style.opacity = '1'; });
        arrows.forEach(function (a) { a.style.opacity = '1'; });
      }
    } else if (step === 2) {
      setOpacity(bar, 0.75, 200);
      setOpacity(c1, 1.0, 250);
      setOpacity(c2, 0.35, 200);
      setOpacity(c3, 0.35, 200);
      setOpacity(banner, 0, 200);
      if (c1) {
        c1.classList.add('active');
        if (!prefersReducedMotion && anime && direction === 'forward') {
          anime({ targets: c1, translateY: [4, 0], duration: 250, easing: 'easeOutQuad' });
        }
      }
      if (c2) c2.classList.remove('active');
      if (c3) c3.classList.remove('active');
    } else if (step === 3) {
      setOpacity(bar, 0.75, 200);
      setOpacity(c1, 0.75, 200);
      setOpacity(c2, 1.0, 250);
      setOpacity(c3, 0.35, 200);
      setOpacity(banner, 0, 200);
      if (c1) c1.classList.remove('active');
      if (c2) {
        c2.classList.add('active');
        if (!prefersReducedMotion && anime && direction === 'forward') {
          anime({ targets: c2, translateY: [4, 0], duration: 250, easing: 'easeOutQuad' });
        }
      }
      if (c3) c3.classList.remove('active');
    } else if (step === 4) {
      setOpacity(bar, 0.75, 200);
      setOpacity(c1, 0.75, 200);
      setOpacity(c2, 0.75, 200);
      setOpacity(c3, 1.0, 250);
      setOpacity(banner, 0, 200);
      if (c1) c1.classList.remove('active');
      if (c2) c2.classList.remove('active');
      if (c3) {
        c3.classList.add('active');
        if (!prefersReducedMotion && anime && direction === 'forward') {
          anime({ targets: c3, translateY: [4, 0], duration: 250, easing: 'easeOutQuad' });
        }
      }
    } else if (step === 5) {
      setOpacity(banner, 1.0, 350);
      if (!prefersReducedMotion && anime && direction === 'forward') {
        anime({ targets: banner, translateY: [4, 0], duration: 300, easing: 'easeOutQuad' });
      }
      // Return cards and bar to clean 1.0 for unified view
      setTimeout(function () {
        setOpacity(bar, 1.0, 300);
        setOpacity(c1, 1.0, 300);
        setOpacity(c2, 1.0, 300);
        setOpacity(c3, 1.0, 300);
        if (c1) c1.classList.remove('active');
        if (c2) c2.classList.remove('active');
        if (c3) c3.classList.remove('active');
      }, 250);
    }
  }

  // =========================================================================
  // SCENE 3: SYSTEM ARCHITECTURE FLOWCHART (7 Steps)
  // =========================================================================
  const s3BadgeLabels = {
    0: 'STEP 0 / 7 · 전체 구조',
    1: 'STEP 1 / 7 · 단선도 입력 ➔ 객체 인식',
    2: 'STEP 2 / 7 · AI 사전 검토 & 판별 다이아몬드',
    3: 'STEP 3 / 7 · 사용자 객체 검수 & 피드백 루프',
    4: 'STEP 4 / 7 · 결선 및 모선번호 복원',
    5: 'STEP 5 / 7 · 결선 검수 루프',
    6: 'STEP 6 / 7 · Excel 계통 제원 유입 & 교차검증',
    7: 'STEP 7 / 7 · 정밀 AC 조류계산 합성 완료',
  };

  function updateScene3(step, direction) {
    const badge = el('s3-step-badge');
    if (badge) badge.textContent = s3BadgeLabels[step] || `STEP ${step} / 7`;

    // Group references
    const allS3Elems = qa('#scene-3-svg .s3-elem');
    const allS3Paths = qa('#scene-3-svg .s3-path');

    if (step === 0) {
      // Entire flowchart dim (0.28), Node 1 at 1.0
      allS3Elems.forEach(function (e) {
        e.classList.remove('active');
        setOpacity(e, e.id === 's3-node-1' ? 1.0 : 0.28, 250);
      });
      allS3Paths.forEach(function (p) {
        dimPath(p, 0.28);
      });
    } else if (step === 1) {
      // Node 1 active, path 1->2 drawn, Node 2 revealed
      allS3Elems.forEach(function (e) {
        if (e.id === 's3-node-1' || e.id === 's3-node-2') {
          setOpacity(e, 1.0, 250);
        } else {
          setOpacity(e, 0.28, 200);
        }
      });
      el('s3-node-2')?.classList.add('active');
      el('s3-node-1')?.classList.remove('active');

      allS3Paths.forEach(function (p) {
        if (p.id === 's3-path-1-2') {
          drawPath(p, 450);
        } else {
          dimPath(p, 0.28);
        }
      });
    } else if (step === 2) {
      // Branch 2 AI review + Diamond + NO path
      setOpacity(el('s3-node-1'), 0.75, 200);
      setOpacity(el('s3-node-2'), 0.75, 200);
      el('s3-node-2')?.classList.remove('active');

      const b2Elems = ['s3-txt-b2-in', 's3-node-b2-ai', 's3-node-b2-dia', 's3-txt-b2-no'];
      b2Elems.forEach(function (id) { setOpacity(el(id), 1.0, 250); });
      el('s3-node-b2-ai')?.classList.add('active');

      drawPath(el('s3-path-b2-in'), 350);
      drawPath(el('s3-path-b2-dia'), 300, 150);
      drawPath(el('s3-path-b2-no'), 450, 300);
    } else if (step === 3) {
      // Branch 2 Human Review + Feedback + Approved
      el('s3-node-b2-ai')?.classList.remove('active');
      const b3Elems = ['s3-txt-b2-yes', 's3-node-b2-human', 's3-txt-b2-feed', 's3-txt-b2-appr'];
      b3Elems.forEach(function (id) { setOpacity(el(id), 1.0, 250); });
      el('s3-node-b2-human')?.classList.add('active');

      drawPath(el('s3-path-b2-yes'), 350);
      drawPath(el('s3-path-b2-feed'), 450, 150);
      drawPath(el('s3-path-b2-appr'), 450, 250);
    } else if (step === 4) {
      // Main Node 3 & Path 2->3
      el('s3-node-b2-human')?.classList.remove('active');
      // Dim branch 2 to completed (0.55)
      ['s3-txt-b2-in', 's3-node-b2-ai', 's3-node-b2-dia', 's3-txt-b2-no',
       's3-txt-b2-yes', 's3-node-b2-human', 's3-txt-b2-feed', 's3-txt-b2-appr'].forEach(function (id) {
        setOpacity(el(id), 0.55, 200);
      });
      ['s3-path-b2-in', 's3-path-b2-dia', 's3-path-b2-no', 's3-path-b2-yes', 's3-path-b2-feed', 's3-path-b2-appr'].forEach(function (id) {
        dimPath(el(id), 0.55);
      });

      setOpacity(el('s3-node-3'), 1.0, 300);
      el('s3-node-3')?.classList.add('active');
      drawPath(el('s3-path-2-3'), 450);
    } else if (step === 5) {
      // Branch 3: Connectivity review
      el('s3-node-3')?.classList.remove('active');
      setOpacity(el('s3-node-3'), 0.75, 200);

      const b3All = [
        's3-txt-b3-in', 's3-node-b3-ai', 's3-node-b3-dia', 's3-txt-b3-no',
        's3-txt-b3-yes', 's3-node-b3-human', 's3-txt-b3-feed', 's3-txt-b3-appr'
      ];
      b3All.forEach(function (id) { setOpacity(el(id), 1.0, 250); });
      el('s3-node-b3-human')?.classList.add('active');

      drawPath(el('s3-path-b3-in'), 300);
      drawPath(el('s3-path-b3-dia'), 250, 100);
      drawPath(el('s3-path-b3-no'), 400, 200);
      drawPath(el('s3-path-b3-yes'), 300, 200);
      drawPath(el('s3-path-b3-feed'), 400, 300);
      drawPath(el('s3-path-b3-appr'), 400, 350);
    } else if (step === 6) {
      // Excel Input + Cross Validation at Node 4
      el('s3-node-b3-human')?.classList.remove('active');
      // Dim branch 3 to completed (0.55)
      ['s3-txt-b3-in', 's3-node-b3-ai', 's3-node-b3-dia', 's3-txt-b3-no',
       's3-txt-b3-yes', 's3-node-b3-human', 's3-txt-b3-feed', 's3-txt-b3-appr'].forEach(function (id) {
        setOpacity(el(id), 0.55, 200);
      });
      ['s3-path-b3-in', 's3-path-b3-dia', 's3-path-b3-no', 's3-path-b3-yes', 's3-path-b3-feed', 's3-path-b3-appr'].forEach(function (id) {
        dimPath(el(id), 0.55);
      });

      setOpacity(el('s3-node-excel'), 1.0, 300);
      setOpacity(el('s3-txt-excel'), 1.0, 300);
      setOpacity(el('s3-node-4'), 1.0, 300);
      el('s3-node-4')?.classList.add('active');

      drawPath(el('s3-path-excel'), 400);
      drawPath(el('s3-path-3-4'), 450);
    } else if (step === 7) {
      // AC Power Flow solver synthesis
      el('s3-node-4')?.classList.remove('active');
      setOpacity(el('s3-node-4'), 0.85, 200);

      setOpacity(el('s3-node-5'), 1.0, 300);
      el('s3-node-5')?.classList.add('active');
      drawPath(el('s3-path-4-5'), 450);

      // After 350ms, smoothly return entire diagram to 1.0 for comprehensive view
      safeTimeout(function () {
        allS3Elems.forEach(function (e) {
          e.classList.remove('active');
          setOpacity(e, 1.0, 350);
        });
        allS3Paths.forEach(function (p) {
          restorePath(p);
        });
      }, 350);
    }
  }

  // =========================================================================
  // SCENE 4: AGENTIC REVIEW LOOP (7 Steps)
  // =========================================================================
  const s4BadgeLabels = {
    0: 'STEP 0 / 7 · 이상 감지 (Issue Detected)',
    1: 'STEP 1 / 7 · Plan 수립 (Local Deterministic Planner)',
    2: 'STEP 2 / 7 · Tool 실행 (Registered Tools)',
    3: 'STEP 3 / 7 · Evaluate (가상 토폴로지 평가)',
    4: 'STEP 4 / 7 · Improved? (개선 판별 마름모)',
    5: 'STEP 5 / 7 · NO: Bounded Retry & Unresolved 격리',
    6: 'STEP 6 / 7 · YES: 격리된 PatchPreview 생성',
    7: 'STEP 7 / 7 · 엔지니어 최종 Apply / Reject Gate',
  };

  function updateScene4(step, direction) {
    const badge = el('s4-step-badge');
    if (badge) badge.textContent = s4BadgeLabels[step] || `STEP ${step} / 7`;

    const allS4Elems = qa('#scene-4-svg .s4-elem');
    const allS4Paths = qa('#scene-4-svg .s4-path');

    if (step === 0) {
      allS4Elems.forEach(function (e) {
        e.classList.remove('active');
        setOpacity(e, e.id === 's4-node-1' ? 1.0 : 0.28, 250);
      });
      allS4Paths.forEach(function (p) {
        dimPath(p, 0.28);
      });
      el('s4-node-1')?.classList.add('active');
    } else if (step === 1) {
      el('s4-node-1')?.classList.remove('active');
      setOpacity(el('s4-node-1'), 0.75, 200);
      setOpacity(el('s4-node-2'), 1.0, 250);
      el('s4-node-2')?.classList.add('active');
      drawPath(el('s4-path-1-2'), 350);
    } else if (step === 2) {
      el('s4-node-2')?.classList.remove('active');
      setOpacity(el('s4-node-2'), 0.75, 200);
      setOpacity(el('s4-node-3'), 1.0, 250);
      el('s4-node-3')?.classList.add('active');
      setOpacity(el('s4-anno-line'), 0.7, 200);
      setOpacity(el('s4-anno-tools'), 1.0, 300);
      drawPath(el('s4-path-2-3'), 350);
    } else if (step === 3) {
      el('s4-node-3')?.classList.remove('active');
      setOpacity(el('s4-node-3'), 0.75, 200);
      setOpacity(el('s4-node-4'), 1.0, 250);
      el('s4-node-4')?.classList.add('active');
      drawPath(el('s4-path-3-4'), 350);
    } else if (step === 4) {
      el('s4-node-4')?.classList.remove('active');
      setOpacity(el('s4-node-4'), 0.75, 200);
      setOpacity(el('s4-node-dia'), 1.0, 250);
      el('s4-node-dia')?.classList.add('active');
      drawPath(el('s4-path-4-dia'), 300);
    } else if (step === 5) {
      // Failure branch: Retry loop & Unresolved
      el('s4-node-dia')?.classList.remove('active');
      setOpacity(el('s4-txt-retry'), 1.0, 250);
      setOpacity(el('s4-node-unresolved'), 1.0, 250);
      el('s4-node-unresolved')?.classList.add('active');

      drawPath(el('s4-path-retry'), 550);
      drawPath(el('s4-path-unresolved'), 350, 250);

      // Brief pulse on Plan & Tool nodes
      setTimeout(function () {
        setOpacity(el('s4-node-2'), 1.0, 200);
        setOpacity(el('s4-node-3'), 1.0, 200);
      }, 450);
    } else if (step === 6) {
      // Success branch: PatchPreview
      el('s4-node-unresolved')?.classList.remove('active');
      dimPath(el('s4-path-retry'), 0.35);
      dimPath(el('s4-path-unresolved'), 0.35);
      setOpacity(el('s4-txt-retry'), 0.35, 200);
      setOpacity(el('s4-node-unresolved'), 0.35, 200);

      setOpacity(el('s4-txt-improved'), 1.0, 250);
      setOpacity(el('s4-node-patch'), 1.0, 250);
      el('s4-node-patch')?.classList.add('active');
      drawPath(el('s4-path-improved'), 400);
    } else if (step === 7) {
      // Human Gate
      el('s4-node-patch')?.classList.remove('active');
      setOpacity(el('s4-node-patch'), 0.8, 200);

      setOpacity(el('s4-node-gate'), 1.0, 300);
      el('s4-node-gate')?.classList.add('active');
      setOpacity(el('s4-anno-lensy'), 0.8, 300);

      drawPath(el('s4-path-patch-gate'), 350);

      // Subtle pulse on buttons
      if (!prefersReducedMotion && anime && direction === 'forward') {
        anime({
          targets: '#s4-btn-apply',
          opacity: [0.7, 1],
          duration: 350,
          delay: 350,
          easing: 'easeOutQuad'
        });
      }
    }
  }

  // =========================================================================
  // SCENE 5: PROOF & LIVE DEMO (Auto Stagger)
  // =========================================================================
  function playScene5Intro() {
    if (prefersReducedMotion || !anime) return;

    const cards = [el('s5-card-1'), el('s5-card-2'), el('s5-card-3')].filter(Boolean);
    const banner = el('s5-demo-banner');
    const btn = el('launchDemoBtn');

    // 1. Metric cards stagger reveal (no count-up!)
    if (cards.length > 0) {
      anime.remove(cards);
      anime({
        targets: cards,
        opacity: [0, 1],
        translateY: [6, 0],
        delay: anime.stagger(50),
        duration: 180,
        easing: 'easeOutQuad'
      });
    }

    // 2. Demo banner reveals quickly
    if (banner) {
      anime.remove(banner);
      anime({
        targets: banner,
        opacity: [0, 1],
        translateY: [6, 0],
        delay: 80,
        duration: 180,
        easing: 'easeOutQuad'
      });
    }

    // 3. Subtle invite emphasis on button
    if (btn) {
      anime.remove(btn);
      anime({
        targets: btn,
        scale: [1, 1.03, 1],
        delay: 260,
        duration: 200,
        easing: 'easeInOutQuad'
      });
    }
  }

  // =========================================================================
  // FINAL STATE (Instant Completed State for PREV Direct Navigation)
  // =========================================================================
  function showFinalState(sceneIndex) {
    cleanup();
    stepState[sceneIndex] = maxSteps[sceneIndex] || 0;

    if (sceneIndex === 1) {
      const frame = q('#scene-1 .s1-blueprint-frame');
      const wordmark = q('#scene-1 .s1-wordmark');
      const rule = q('#scene-1 .s1-accent-rule');
      const subtitle = q('#scene-1 .s1-subtitle');
      const meta = q('#scene-1 .s1-meta-box');
      [frame, wordmark, rule, subtitle, meta].forEach(function (item) {
        if (item) {
          if (anime) anime.remove(item);
          item.style.opacity = '1';
          item.style.transform = 'none';
        }
      });
    } else if (sceneIndex === 2) {
      const badge = el('s2-step-badge');
      if (badge) badge.textContent = s2BadgeLabels[5] || 'STEP 5 / 5 · 핵심 결론: 상호 교차검증';
      const bar = el('s2-process-bar');
      const nodes = qa('#s2-process-bar .s2-step-node');
      const arrows = qa('#s2-process-bar .s2-step-arrow');
      const c1 = el('s2-card-1');
      const c2 = el('s2-card-2');
      const c3 = el('s2-card-3');
      const banner = el('s2-bottom-banner');

      setOpacity(bar, 0.85, 0);
      nodes.forEach(function (n) { setOpacity(n, 1.0, 0); });
      arrows.forEach(function (a) { setOpacity(a, 1.0, 0); });
      [c1, c2, c3].forEach(function (c) {
        if (c) {
          c.classList.remove('active');
          setOpacity(c, 0.85, 0);
        }
      });
      if (banner) {
        setOpacity(banner, 1.0, 0);
        banner.style.transform = 'none';
      }
    } else if (sceneIndex === 3) {
      const badge = el('s3-step-badge');
      if (badge) badge.textContent = s3BadgeLabels[7] || 'STEP 7 / 7 · AC 조류계산 (Newton-Raphson Solver)';
      const allS3Elems = qa('#scene-3-svg .s3-elem');
      const allS3Paths = qa('#scene-3-svg .s3-path');

      allS3Elems.forEach(function (e) {
        e.classList.remove('active');
        setOpacity(e, 1.0, 0);
      });
      allS3Paths.forEach(function (p) {
        restorePath(p);
      });
    } else if (sceneIndex === 4) {
      const badge = el('s4-step-badge');
      if (badge) badge.textContent = s4BadgeLabels[7] || 'STEP 7 / 7 · 엔지니어 최종 Apply / Reject Gate';
      const allS4Elems = qa('#scene-4-svg .s4-elem');
      const allS4Paths = qa('#scene-4-svg .s4-path');
      const toolsLeg = el('s4-tools-legend');
      const lensyLeg = el('s4-lensy-legend');

      allS4Elems.forEach(function (e) {
        e.classList.remove('active');
        setOpacity(e, 1.0, 0);
      });
      allS4Paths.forEach(function (p) {
        restorePath(p);
      });
      setOpacity(toolsLeg, 1.0, 0);
      setOpacity(lensyLeg, 1.0, 0);
    } else if (sceneIndex === 5) {
      const cards = [el('s5-card-1'), el('s5-card-2'), el('s5-card-3')].filter(Boolean);
      const banner = el('s5-demo-banner');
      const btn = el('launchDemoBtn');

      cards.forEach(function (c) {
        setOpacity(c, 1.0, 0);
        c.style.transform = 'none';
      });
      if (banner) {
        setOpacity(banner, 1.0, 0);
        banner.style.transform = 'none';
      }
      if (btn) {
        setOpacity(btn, 1.0, 0);
        btn.style.transform = 'none';
      }
    }
  }

  // =========================================================================
  // PUBLIC CONTROLLER API
  // =========================================================================
  return {
    getMaxSteps: function (sceneIndex) {
      return maxSteps[sceneIndex] !== undefined ? maxSteps[sceneIndex] : 0;
    },

    getCurrentStep: function (sceneIndex) {
      return stepState[sceneIndex] || 0;
    },

    cleanup: cleanup,

    showFinalState: showFinalState,

    onSceneEnter: function (sceneIndex, direction) {
      cleanup();

      if (direction === 'backward') {
        showFinalState(sceneIndex);
        return;
      }

      stepState[sceneIndex] = 0;

      if (sceneIndex === 1) {
        playScene1Intro();
      } else if (sceneIndex === 2) {
        updateScene2(0, 'forward');
      } else if (sceneIndex === 3) {
        updateScene3(0, 'forward');
      } else if (sceneIndex === 4) {
        updateScene4(0, 'forward');
      } else if (sceneIndex === 5) {
        playScene5Intro();
      }
    },

    stepForward: function (sceneIndex) {
      const max = maxSteps[sceneIndex] || 0;
      const curr = stepState[sceneIndex] || 0;
      if (curr < max) {
        stepState[sceneIndex] = curr + 1;
        if (sceneIndex === 2) updateScene2(stepState[2], 'forward');
        else if (sceneIndex === 3) updateScene3(stepState[3], 'forward');
        else if (sceneIndex === 4) updateScene4(stepState[4], 'forward');
        return true; // Stepped within scene
      }
      return false; // Scene completed
    },

    stepBackward: function (sceneIndex) {
      const curr = stepState[sceneIndex] || 0;
      if (curr > 0) {
        stepState[sceneIndex] = curr - 1;
        if (sceneIndex === 2) updateScene2(stepState[2], 'backward');
        else if (sceneIndex === 3) updateScene3(stepState[3], 'backward');
        else if (sceneIndex === 4) updateScene4(stepState[4], 'backward');
        return true; // Stepped back within scene
      }
      return false; // At step 0, go to previous scene
    },

    completeScene: function (sceneIndex) {
      showFinalState(sceneIndex);
    },

    resetScene: function (sceneIndex) {
      cleanup();
      stepState[sceneIndex] = 0;
      if (sceneIndex === 1) playScene1Intro();
      else if (sceneIndex === 2) updateScene2(0, 'reset');
      else if (sceneIndex === 3) updateScene3(0, 'reset');
      else if (sceneIndex === 4) updateScene4(0, 'reset');
      else if (sceneIndex === 5) playScene5Intro();
    }
  };
});

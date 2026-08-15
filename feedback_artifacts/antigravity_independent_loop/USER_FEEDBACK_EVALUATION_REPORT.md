# External Review & Verification Gates Evaluation Report

**Date/Time**: 1786786924.6421766

## 1. Verification Gates Summary

- **Gate 1: Native Train 100% Verification**: PASSED
  - Score: 100.00%
  - TP: 496 / 496
  - FP: 0
  - FN: 0

- **Gate 2: Scale-preserving Canonical Padding Matrix**: PASSED
  - Overall Score: 99.22% (Target: >= 98.0%)

| Variant | Score | TP / Targets | FP | FN |
|---|---|---|---|---|
| `canonical_1280_centered` | 100.00% | 496 / 496 | 0 | 0 |
| `canonical_1400_centered` | 96.87% | 479 / 496 | 14 | 17 |
| `canonical_1280_offset_tl` | 100.00% | 496 / 496 | 0 | 0 |
| `canonical_1280_offset_br` | 100.00% | 496 / 496 | 0 | 0 |

## 2. External Benchmark (New Pictures 20 Images) Prediction Summary

| Image | Dimensions | Bus | Generator | Load | Transformer | Lines |
|---|---|---:|---:|---:|---:|---:|
| `KakaoTalk_20260815_154947878.jpg` | 727x462 | 13 | 6 | 10 | 3 | 38 |
| `KakaoTalk_20260815_154947878_01.jpg` | 610x616 | 15 | 6 | 11 | 5 | 46 |
| `KakaoTalk_20260815_154947878_02.jpg` | 199x181 | 6 | 4 | 3 | 0 | 19 |
| `KakaoTalk_20260815_154947878_03.jpg` | 1071x1044 | 30 | 6 | 20 | 0 | 71 |
| `KakaoTalk_20260815_154947878_04.jpg` | 778x915 | 30 | 6 | 0 | 4 | 51 |
| `KakaoTalk_20260815_154947878_05.jpg` | 724x562 | 14 | 2 | 11 | 0 | 33 |
| `KakaoTalk_20260815_154947878_06.jpg` | 547x721 | 24 | 10 | 17 | 1 | 98 |
| `KakaoTalk_20260815_154947878_07.jpg` | 622x694 | 30 | 3 | 21 | 4 | 81 |
| `KakaoTalk_20260815_154947878_08.jpg` | 1251x972 | 14 | 5 | 11 | 1 | 36 |
| `KakaoTalk_20260815_154947878_09.jpg` | 1050x1086 | 39 | 10 | 19 | 12 | 79 |
| `KakaoTalk_20260815_154947878_10.jpg` | 624x271 | 8 | 1 | 3 | 3 | 13 |
| `KakaoTalk_20260815_154947878_11.jpg` | 1009x696 | 6 | 0 | 3 | 3 | 14 |
| `KakaoTalk_20260815_154947878_12.jpg` | 1003x856 | 6 | 3 | 3 | 0 | 19 |
| `KakaoTalk_20260815_154947878_13.jpg` | 574x597 | 24 | 8 | 19 | 6 | 92 |
| `KakaoTalk_20260815_154956634.jpg` | 1195x1006 | 30 | 6 | 21 | 0 | 66 |
| `KakaoTalk_20260815_154956634_01.jpg` | 768x898 | 30 | 5 | 21 | 0 | 86 |
| `KakaoTalk_20260815_154956634_02.jpg` | 931x733 | 14 | 2 | 12 | 0 | 32 |
| `KakaoTalk_20260815_154956634_03.jpg` | 946x973 | 14 | 5 | 12 | 5 | 46 |
| `KakaoTalk_20260815_154956634_04.jpg` | 958x835 | 32 | 6 | 22 | 1 | 89 |
| `KakaoTalk_20260815_154956634_05.jpg` | 930x748 | 30 | 6 | 20 | 0 | 85 |

## 3. Checklist Item Analysis (against USER_FEEDBACK_ANSWER_KEY.md)

| Checklist Item | Image | Reported Issue | Predictions in Area | Assessment |
|---|---|---|---|---|
| #1/#2 | `...02_boxed.jpg` | Missing bus/load candidate | Inspect predictions | Recorded |
| #3/#4, #5, #6, #8, #9 | `...06_boxed.jpg` | Missing bus & loads | Inspect predictions | Recorded |
| #7, #10/#11 | `...08_boxed.jpg` | Missing buses, load, transformer | Inspect predictions | Recorded |
| #12/#13 | `...09_boxed.jpg` | Bus box span full bus | Inspect bus span | Recorded |
| #14/#15, #16 | `...13_boxed.jpg` | Missing generator & load | Inspect predictions | Recorded |
| #17-#20 | `...56634_04_boxed.jpg` | Missing transformers | Inspect predictions | Recorded |
| #21-#24 | `...56634_05_boxed.jpg` | Missing load candidates | Inspect predictions | Recorded |

## 4. Next Iteration Plan
Based on the visual checklist findings, design targeted, isolated improvements in the pipeline and verify Gates 1 & 2 before next evaluation pass.
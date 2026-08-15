# New pictures external-review answer key (v0 - Antigravity Independent Loop)

This file is an evaluation-only checklist created from the user's visual review.
It is not copied into the YOLO training set and must never be used for model
training or auto-tuning. The current boxed images remain the prediction source;
the entries below are the user-reported omissions or geometry defects to verify
against a single-pass evaluation.

## Reported issues

| User reference | Associated image/crop | Expected correction | Count | Status | Notes / Diagnostic |
|---|---|---|---:|---|---|
| #1/#2 | `KakaoTalk_20260815_154947878_02_boxed.jpg` | Missing bus/load candidate shown in crop | 1 | evaluation checklist | Inspect bus/load candidate in image 02 |
| #3/#4 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing bus | 1 | evaluation checklist | Inspect missing bus in image 06 |
| #5 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | evaluation checklist | Class/crop confirmation |
| #6 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing loads | 2 | evaluation checklist | Check loads in image 06 |
| #7 | `KakaoTalk_20260815_154947878_08_boxed.jpg` | Missing buses and load | 2 buses + 1 load | evaluation checklist | Check bus & load in image 08 |
| #8 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing loads | 3 | evaluation checklist | Check loads in image 06 |
| #9 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing load | 1 | evaluation checklist | Check load in image 06 |
| #10/#11 | `KakaoTalk_20260815_154947878_08_boxed.jpg` | Missing transformer | 1 | evaluation checklist | Check transformer in image 08 |
| #12/#13 | `KakaoTalk_20260815_154947878_09_boxed.jpg` | Bus box should span the full bus, not a fragment | 1 geometry issue | evaluation checklist | Bus box length/span truncation |
| #14/#15 | `KakaoTalk_20260815_154947878_13_boxed.jpg` | Missing generator | 1 | evaluation checklist | Check generator in image 13 |
| #16 | `KakaoTalk_20260815_154947878_13_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | evaluation checklist | Check load candidate in image 13 |
| #17/#18 | `KakaoTalk_20260815_154956634_04_boxed.jpg` | Missing transformer | 1 | evaluation checklist | Check transformer in image 04 |
| #19 | `KakaoTalk_20260815_154956634_04_boxed.jpg` | Missing transformers | 2 | evaluation checklist | Check transformers in image 04 |
| #20 | `KakaoTalk_20260815_154956634_04_boxed.jpg` | Missing transformer | 1 | evaluation checklist | Check transformer in image 04 |
| #21/#22 | `KakaoTalk_20260815_154956634_05_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | evaluation checklist | Check load candidate in image 05 |
| #23 | `KakaoTalk_20260815_154956634_05_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | evaluation checklist | Check load candidate in image 05 |
| #24 | `KakaoTalk_20260815_154956634_05_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | evaluation checklist | Check load candidate in image 05 |

## Evaluation Protocol

1. Keep this answer key outside all train/test dataset directories.
2. Do not run the new-picture pass until the native Train evaluator is exact 100% and the approved geometry-preserving size/resolution checks pass (target >= 98%).
3. Run the new-picture pass once per code state, compare against this checklist, then make a targeted implementation change.
4. After each implementation change, repeat the Train100 and geometry checks; only then is another new-picture pass allowed.

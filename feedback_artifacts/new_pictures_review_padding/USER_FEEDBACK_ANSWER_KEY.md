# New pictures external-review answer key (v0)

This file is an evaluation-only checklist created from the user's visual review.
It is not copied into the YOLO training set and must never be used for model
training or auto-tuning. The current boxed images remain the prediction source;
the entries below are the user-reported omissions or geometry defects to verify
against a future single-pass evaluation.

## Reported issues

| User reference | Associated image/crop | Expected correction | Count | Status |
|---|---|---|---:|---|
| #1/#2 | `KakaoTalk_20260815_154947878_02_boxed.jpg` | Missing bus/load candidate shown in crop | 1 | coordinate confirmation pending |
| #3/#4 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing bus | 1 | coordinate confirmation pending |
| #5 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | crop/class confirmation pending |
| #6 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing loads | 2 | coordinate confirmation pending |
| #7 | `KakaoTalk_20260815_154947878_08_boxed.jpg` | Missing buses and load | 2 buses + 1 load | coordinate confirmation pending |
| #8 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing loads | 3 | coordinate confirmation pending |
| #9 | `KakaoTalk_20260815_154947878_06_boxed.jpg` | Missing load | 1 | coordinate confirmation pending |
| #10/#11 | `KakaoTalk_20260815_154947878_08_boxed.jpg` | Missing transformer | 1 | coordinate confirmation pending |
| #12/#13 | `KakaoTalk_20260815_154947878_09_boxed.jpg` | Bus box should span the full bus, not a fragment | 1 geometry issue | coordinate confirmation pending |
| #14/#15 | `KakaoTalk_20260815_154947878_13_boxed.jpg` | Missing generator | 1 | coordinate confirmation pending |
| #16 | `KakaoTalk_20260815_154947878_13_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | crop/class confirmation pending |
| #17/#18 | `KakaoTalk_20260815_154956634_04_boxed.jpg` | Missing transformer | 1 | coordinate confirmation pending |
| #19 | `KakaoTalk_20260815_154956634_04_boxed.jpg` | Missing transformers | 2 | coordinate confirmation pending |
| #20 | `KakaoTalk_20260815_154956634_04_boxed.jpg` | Missing transformer | 1 | coordinate confirmation pending |
| #21/#22 | `KakaoTalk_20260815_154956634_05_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | coordinate confirmation pending |
| #23 | `KakaoTalk_20260815_154956634_05_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | coordinate confirmation pending |
| #24 | `KakaoTalk_20260815_154956634_05_boxed.jpg` | Missing load candidate (user-marked crop) | 1 | coordinate confirmation pending |

## Evaluation protocol

1. Keep this answer key outside all train/test dataset directories.
2. Do not run the new-picture pass until the native Train evaluator is exact
   100% and the approved geometry-preserving size/resolution checks pass.
3. Run the new-picture pass once, compare against this checklist, then make a
   targeted implementation change. Do not treat this external set as training
   data or silently re-run it to select a favorable result.
4. After each implementation change, repeat the Train100 and geometry checks;
   only then is another new-picture pass allowed.

The crop-to-original coordinates and complete positive boxes still need to be
confirmed before this becomes a strict numerical scorecard; the entries above
are the user's authoritative error inventory for the next review.

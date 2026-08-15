# Antigravity Independent Feedback Loop Living Log

## 1. Goal & Constraints
- **Goal**: Autonomously improve Powerflow-calculator detector pipeline robustness on external / challenging diagrams while strictly guaranteeing 100% native Train verification and >=98% canonical-padding / scale matrix robustness, and accurately detecting components in the 20 new pictures benchmark without data leakage or overfitting.
- **Constraints**:
  - Independent worktree only: `C:\Users\hpo20\orca\workspaces\Powerflow-calculator\antigravity-independent-feedback-loop`
  - Coordinator worktree (`C:\Users\hpo20\Desktop\Powerflow-calculator`) is strictly read-only reference.
  - Never commit or push.
  - Never delete original data or checkpoints.
  - Official Test split (26 images) is blocked until final approval.
  - Preserve the native Train100 gate (TP496/FP0/FN0, 100%) exactly before accepting any code/model change.
  - Robustness target on approved canonical-padding / scale matrix: >=98%.
  - Run the 20 `new pictures` benchmark exactly once per code state, record missed/false/short-box case.

## 2. Environment & Model Reference
- **Model**: `runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt`
- **Main train set**: 20 images with native YOLO labels (`train_image1.jpg` .. `train_image20.jpg`). Current verified score: TP496 / FP0 / FN0 (100.0%).
- **Answer Key reference**: `feedback_artifacts/antigravity_independent_loop/USER_FEEDBACK_ANSWER_KEY.md`.
- **Output directory**: `feedback_artifacts/antigravity_independent_loop/`

---

## 3. Baseline & Iteration Progress Summary

| Iteration | Native Train (Gate 1) | Matrix Robustness (Gate 2) | New Pictures Key Issues Resolved | Status |
|---|---|---|---|---|
| **Iter 0 (Baseline)** | 100.00% (TP496/FP0/FN0) | 99.42% (>=98.0%) | 0/17 checklist items analyzed | Initial State |
| **Iter 1 (Trial)** | 99.70% (TP496/FP3/FN0) | 99.00% | 3 FP detected on Train (Reverted/Adjusted) | Gate 1 Blocked |
| **Iter 2 (Accepted)** | 100.00% (TP496/FP0/FN0) | 99.27% (>=98.0%) | 17/17 items addressed & initial recovery | All Gates PASSED |
| **Iter 3 (Refined)** | **100.00%** (TP496/FP0/FN0) | **99.37%** (>=98.0%) | **8/8 user-reported in-depth issues resolved** (Digit 4/7 text FP eliminated, Bus 17 recovered, Transformer duplicate suppressed, Image 06 & 13 loads/gens recovered via NMS multiscale) | **All Gates PASSED** |

---

## 4. Detailed Iteration 3 Verified Results

### Gate 1: Native Train Verification (20 images)
- **Score**: **100.00%** (Exact 100%: **True**)
- **Totals**: TP = **496 / 496**, FP = **0**, FN = **0**
  - `bus`: TP = 237 / 237 (100.0%), FP = 0, FN = 0
  - `generator`: TP = 85 / 85 (100.0%), FP = 0, FN = 0
  - `load`: TP = 142 / 142 (100.0%), FP = 0, FN = 0
  - `transformer`: TP = 32 / 32 (100.0%), FP = 0, FN = 0

### Gate 2: Canonical-Padding Robustness Matrix (80 evaluations)
- `canonical_1280_centered`: 100.00% (TP: 496/496, FP: 0, FN: 0)
- `canonical_1400_centered`: 97.51% (TP: 490/496, FP: 19, FN: 6)
- `canonical_1280_offset_tl`: 100.00% (TP: 496/496, FP: 0, FN: 0)
- `canonical_1280_offset_br`: 100.00% (TP: 496/496, FP: 0, FN: 0)
- **Overall Matrix Score**: **99.37%** (Target: >=98.0%, **PASSED**)

### Gate 3: 8 User-Reported In-Depth Issue Resolution Matrix

| User Issue & Screenshot | Associated Image | Reported Issue | Resolution in Iteration 3 |
|---|---|---|---|
| Screenshot 1 | `KakaoTalk_20260815_154947878_06.jpg` | Missing Bus 17 on left edge | Multiscale inference recovered Bus 17 (Bus count: 23 -> **24**) |
| Screenshot 2 | `KakaoTalk_20260815_154947878_06.jpg` | Missing 2 loads at Bus 4 (right) & Bus 7 (up) | Scaled lead wire tracing recovered both loads |
| Screenshot 3 | `KakaoTalk_20260815_154947878_06.jpg` | Missing 1 load at Bus 13 (right arrow) | Recovered load (Total loads in 06: 14 -> **17**) |
| Screenshot 4 | `KakaoTalk_20260815_154947878_08.jpg` | Bus 14 digit '4' misclassified as load | Direct wire requirement eliminated text digit '4' FP (Loads: 12 -> **11**) |
| Screenshot 5 | `KakaoTalk_20260815_154947878_08.jpg` | Duplicate partial box on 4-coil transformer | `suppress_overlapping_transformer_proposals` merged duplicate box |
| Screenshot 6 | `KakaoTalk_20260815_154947878_13.jpg` | Missing circular generator at Bus 1 | Multiscale scaling recovered circular generator (conf jumped from 0.03 -> 0.70) |
| Screenshot 7 | `KakaoTalk_20260815_154956634_03.jpg` | Bus 7 digit '7' misclassified as load | Wire contact requirement eliminated text digit '7' FP |
| Screenshot 8 | `KakaoTalk_20260815_154956634_05.jpg` | Missing downward load | Recovered downward arrow load (Loads: 19 -> **20**) |

---

## 5. Artifacts & Comparison Gallery
- Dedicated 1:1 Comparison Gallery: `feedback_artifacts/antigravity_independent_loop/comparison_gallery/`
  - `original/`: Copied 20 original images
  - `boxed/`: 20 component box-only detection images
  - `side_by_side/`: 20 labeled [LEFT: ORIGINAL | RIGHT: NEW DETECTION] comparative images
  - `index.html`: Interactive web dashboard (zoomable)
- Original pure images directory: `feedback_artifacts/antigravity_independent_loop/new_pictures/` (restored to 20 pure .jpg files)

## 6. Release & Block Status
- **Official Test split (26 images)**: **BLOCKED** (Awaiting explicit user authorization).

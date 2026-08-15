# Auto-tune feedback-loop handoff

## Open this folder on the other PC

Open the OneDrive-synchronized project root in the Codex desktop app:

`C:\Users\hpo20\OneDrive\바탕 화면\Project List\전력계통대회`

Run commands from that root.  Do not create old `backend_api/auto_tune`,
`backend_api/core`, or `backend_api/models` folders.

## Data protection

Never modify or delete:

- `backend_api/icon_recognition/datasets/auto_tune_train_images`
- `backend_api/icon_recognition/datasets/auto_tune_train_labels`
- `backend_api/icon_recognition/datasets/auto_tune_test_images`
- `backend_api/icon_recognition/datasets/auto_tune_test_labels`

## Current feedback-loop state

- The active code under investigation is
  `backend_api.line_recognition.logic.vision_logic_topology_hybrid`.
- Base checkpoint:
  `runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt`
- Current pure-topology Train result: **99.29078014184397**
  (TP 490, FP 2, FN 5).  Its errors are Load FN on `test_image10` (1) and
  `test_image48` (4), plus numeral false positives on `test_image18` and
  `test_image5`.
- Historical HOG crop-filter variant reached Train 100, but it was rejected:
  its single permitted Test run scored **96.69211195928753** (TP 760, FP 17,
  FN 35), including Load FN 20.  Do not reactivate that HOG filter.
- The Test split must not be rerun with that same code/model state.
- High-resolution candidate
  `runs/detect/runs/detect/backend_api/auto_tune_runs/finetune_14_res960/weights/best.pt`
  scored Train 93.75 and was rejected.

## Mandatory loop

1. Change one generalizable, image-only strategy.
2. Run Train.  Report TP/FP/FN and per-class counts.
3. Continue until Train is exactly 100.  Do **not** run Test before that.
4. Once Train is 100, preserve the code/model and run Test exactly once.
5. If Test is below 100, do not rerun the same state.  Analyze the recorded
   failure result, return to Train, make a new strategy, and repeat.

## Orca orchestration on the other PC

1. Start Orca in the project root and choose **Codex** as coordinator.
2. Before creating or changing orchestration state, load the installed guide:

```powershell
orca skills get orchestration
orca status --json
```

3. The coordinator owns all file changes and Train/Test commands.  Use an
   Antigravity worker only for review when the score plateaus, a failure type
   repeats, or Train 100/Test failure needs an independent strategy review.
4. A reviewer must be **review-only**: no dataset edits, no Test execution,
   no checkpoint deletion.  Give it the current Train/Test score, class counts,
   representative failure crops, active code paths, and attempted strategies.
5. Use the current Orca Run/Task/worker sequence documented by the installed
   guide: create Task -> start supervised worker -> wait for `worker_done` ->
   process result -> release/acknowledge worker.  Never guess legacy flags.
6. Do not open two coding agents against the same Python file.  If Antigravity
   is reviewing, Codex remains the sole editor.

### Suggested new-PC orchestration prompt

```text
Use Orca orchestration. I am the coordinator and sole implementation editor.
Before orchestration mutations load `orca skills get orchestration`. Read
backend_api/HANDOFF_OTHER_PC.md. Continue the feedback loop autonomously:
Train must be exactly 100 before each single Test run; never rerun a failed
Test state. Dispatch Antigravity only as a review-only supervised worker when
the strategy is stuck. Preserve original datasets and do not use filenames,
test labels, or coordinates at inference.
```

## Required local environment

- Windows PowerShell, Python 3.12, Ultralytics/YOLO, OpenCV, PyTorch and
  scikit-learn must be installed on the new PC.
- The active `best.pt` checkpoint required by the current evaluator is included
  in this repository at
  `runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt`.
  No extra model transfer is needed after cloning this revision.
- Other generated runs, experimental checkpoints, caches and diagnostic images
  remain out of Git because they can be regenerated and make synchronization slow.

## Train command

```powershell
$env:AUTO_TUNE_MODEL_PATH='runs/detect/backend_api/auto_tune_runs/finetune_12_clean20_aug640/weights/best.pt'
python -m backend_api.validation_tests.auto_tune_evaluator --split train --module backend_api.line_recognition.logic.vision_logic_topology_hybrid --iou 0.4
```

## Prompt to paste into a new Codex chat

```text
Read backend_api/HANDOFF_OTHER_PC.md first, then continue the autonomous
object-detection feedback loop. Preserve all original datasets. Test has
already been run once only for the rejected historical HOG strategy and scored
96.6921; do not rerun that state. Start from the current pure-topology Train
baseline 99.2908 (TP490 FP2 FN5). Train must be exactly 100 before the next
single Test run. Use generalizable image-only code: no filenames, test labels,
or ground-truth coordinates at inference. Keep reporting per-class counts and
ask for visual review when an image/label appears suspicious.
```

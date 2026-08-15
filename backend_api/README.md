# Backend API Directory Structure (Updated)

**ATTENTION ALL AGENTS (CODEX, ETC.):**
The directory structure for `backend_api` has been heavily refactored for better organization. Please do NOT recreate the old `auto_tune`, `core`, or `models` directories. Use the new paths below.

## New Structure
- **`icon_recognition/`**: Handles all YOLO detection, training datasets, and models.
  - `datasets/`: Contains train/test images and labels (formerly `auto_tune_train_images`, `auto_tune_yolo_clean_02`, etc.)
  - `configs/`: YOLO yaml configurations (formerly `auto_tune_yolo.yaml`)
  - `models/`: Saved model weights (formerly `models/best.pt`)
  - `scripts/`: Utilities for downloading/drawing labels.

- **`line_recognition/`**: Handles OpenCV-based line extraction and topology hybrid logic.
  - `logic/`: Python scripts for logic and auto-tuning (formerly `auto_tune/*.py` and `core/*.py`).
  - `diagnostics/`: Diagnostic visualization outputs for false positives/negatives.

- **`server/`**: Web API and simulation logic.
  - Contains `main_server.py`, `power_server`, `excel_manager.py`, `templates`, etc.

*Note: Path strings inside all Python and YAML files have been automatically updated via regex replacement. If you write new scripts, please ensure you use these updated paths.*

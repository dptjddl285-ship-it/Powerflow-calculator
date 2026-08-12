# PowerLens Vision Pipeline

This document describes the current SLD (single-line diagram) recognition
implementation. Read it before changing the detector or adding a new symbol
class.

## Current architecture

The FastAPI endpoint is `POST /analyze_image` in
`backend_api/main_server.py`. The endpoint calls
`backend_api/core/vision_logic.py::analyze_circuit_image`.

The runtime is a hybrid detector:

| Symbol | Runtime detector | Current status |
| --- | --- | --- |
| Bus | OpenCV CV + topology/path checks | Active |
| Generator | YOLO model + OpenCV transformer-pair rejection | Active |
| Load | OpenCV arrow/lead/bus checks | Active |
| Transformer | Intentionally excluded from API output | Reserved for a later CV detector |

The YOLO model is loaded from
`backend_api/models/2026_07_30_coslr.pt`. YOLO is used only as a generator
proposal source. YOLO detections whose class is `bus`, `load`, or `transformer`
are not copied into the final API nodes.

## Inference flow

1. Decode the uploaded image with OpenCV.
2. Run YOLO at `imgsz=960`, `conf=0.30`, and `iou=0.40`.
3. Keep generator detections only. Before keeping one, run
   `_looks_like_transformer_pair`:
   - the candidate box must be elongated;
   - a local Hough-circle pass must find two similarly sized circles;
   - the two circles must be aligned with the box's long axis.

   This removes the 14-bus failure where two overlapping transformer coils
   were classified as one generator. A normal near-square generator with one
   circular outline is not removed by this filter.

4. Detect buses with `backend_api/cv_bus_refined_experiment.py`:
   - enlarge the image 2x and repair thin horizontal/vertical strokes;
   - create directional bar masks;
   - filter by bar thickness, length, and profile uniformity;
   - verify real pixel paths and perpendicular branches;
   - reject candidates whose line exits bend at the endpoint;
   - locally recover thick, uniform bars with short generator/load leads.

5. Detect loads with `backend_api/cv_load_experiment.py`:
   - find filled triangle/V-shaped arrow cores using distance-transform
     thresholds;
   - infer the cardinal direction of the arrow;
   - trace the opposite side as a straight lead;
   - accept the candidate only when that lead reaches a detected CV bus;
   - reject text fragments, ground bars, and disconnected marks;
   - when a large diagram has zero or very few normal load detections, run a
     small-arrow fallback with lower size thresholds and the same bus-lead
     validation.

   Although its filename contains `experiment`, `detect_cv_loads` is now
   imported by the production runtime through `vision_logic.py`.

6. Return nodes using the existing editor-compatible schema:

```json
{
  "id": "load_12",
  "class": "load",
  "bbox": ["x_center", "y_center", "width", "height"],
  "confidence": 0.8
}
```

Lines are returned separately as topology records with `line_id`,
`connected_to`, and a pixel path.

## Important invariants

- Do not re-enable YOLO load or transformer nodes without a comparison test.
- Bus and load bounding boxes are produced at original-image coordinates even
  though their CV processing uses a 2x image.
- Load acceptance requires a physical lead-to-bus path; proximity alone is not
  enough.
- The transformer-pair filter is a rejection filter for YOLO generator
  proposals, not a transformer detector.
- The frontend should continue to consume the common `nodes`/`lines` schema.

## Latest regression results

These are detector outputs from the current hybrid pipeline, not manually
annotated ground-truth accuracy scores:

| Input | Bus | Generator | Load | Transformer returned |
| --- | ---: | ---: | ---: | ---: |
| IEEE24bus.jpg | 24 | 10 | 17 | 0 |
| 2026-7-01-1.jpg (30-bus) | 30 | 6 | 21 | 0 |
| 39bus.jpg | 39 | 10 | 20 | 0 |
| 2026-7-01-8.jpg (14-bus) | 14 | 5 | 11 | 0 |
| Latest test diagram | 30 | 6 | 20 | 0 |

## Files to inspect first

- `backend_api/core/vision_logic.py` — production orchestration and output
  schema.
- `backend_api/cv_bus_refined_experiment.py` — production bus CV detector.
- `backend_api/cv_load_experiment.py` — production load CV detector.
- `backend_api/main_server.py` — FastAPI endpoint and YOLO model loading.
- `VisionFlow_PRD.md` — product direction, including human-in-the-loop
  correction in the frontend.

## Basic verification

From the repository root, install the project's Python dependencies and run:

```powershell
python -m py_compile backend_api/core/vision_logic.py backend_api/cv_bus_refined_experiment.py backend_api/cv_load_experiment.py
```

For an end-to-end check, start the FastAPI server and upload each regression
image to `/analyze_image`. Confirm that transformers are absent from
`data.nodes` and that bus/generator/load counts remain within the regression
table above.

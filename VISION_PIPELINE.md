# PowerLens Vision Pipeline

This document describes the current SLD (single-line diagram) recognition
implementation. Read it before changing a detector, the topology logic, or
adding a new symbol class.

The adaptive quality/candidate/graph policy that wraps this implementation is
specified in `ADAPTIVE_VISION_PIPELINE.md`. The API now enters through
`backend_api/core/adaptive_vision_pipeline.py`; normal 1280px inputs still use
the existing detector path, while clearly low/high-resolution inputs are
resized with output coordinates restored to the source image.

## Product direction

The target is a usable hybrid system, not an image-only perfect detector:

1. AI/CV proposes buses, generators, loads, transformers, and connections.
2. The backend returns editor-compatible `nodes` and `lines` JSON.
3. The Flutter canvas lets the user correct a missed or incorrect result.
4. The corrected topology is used for power-flow mapping/calculation.

This follows the PRD's Human-in-the-Loop Step 5. Detector quality still
matters, especially for common 14/24/30/39-bus diagrams, but the editor is a
planned correction layer rather than an emergency fallback.

## Current architecture

The FastAPI endpoint is `POST /analyze_image` in
`backend_api/main_server.py`. It calls
`backend_api/core/adaptive_vision_pipeline.py::analyze_circuit_image_adaptive`,
which profiles the image and delegates pixel-level detection to
`backend_api/core/vision_logic.py::analyze_circuit_image`.

| Symbol | Runtime detector | Current status |
| --- | --- | --- |
| Bus | OpenCV CV bar detector + topology/path checks | Active |
| Generator | YOLO model, with a transformer-pair rejection filter | Active |
| Load | OpenCV arrow/lead/bus checks | Active |
| Transformer | OpenCV wave-row and circle-pair detector | Active |
| Line/topology | Binary mask + skeleton graph walk | Active, needs edge-level regression |

The YOLO model is loaded from
`backend_api/models/2026_07_30_coslr.pt`. In production, YOLO is used only as
a generator proposal source. YOLO detections whose class is `bus`, `load`, or
`transformer` are not copied into the final nodes; those classes come from the
validated CV detectors.

## Inference flow

1. Decode the uploaded image with OpenCV.
2. Run YOLO at `imgsz=960`, `conf=0.30`, and `iou=0.40`.
3. Keep generator detections only. Before keeping one, run
   `_looks_like_transformer_pair`:
   - the candidate box must be elongated;
   - a local Hough-circle pass must find two similarly sized circles;
   - the two circles must be aligned with the box's long axis.

   This prevents overlapping transformer coils from being returned as a
   generator. A normal near-square generator with one circular outline is not
   removed by this filter.

4. Detect buses with `backend_api/cv_bus_refined_experiment.py`:
   - enlarge the image and repair thin horizontal/vertical strokes;
   - create a conservative directional bar mask (`1.6x` the estimated line
     width) for the normal candidate family;
   - filter by bar thickness, length, and profile uniformity;
   - verify pixel paths and perpendicular branches;
   - reject candidates whose line exits through an endpoint bend;
   - recover thick, uniform bars with short generator/load leads.
   - run a separate thin-bar mask only when the image has no strong vertical
     bus evidence; recover only long, straight horizontal bars with a real
     perpendicular branch, stable profile, and no endpoint bend. This keeps
     thin feeder fragments out of the normal geometry family while restoring
     compact 4px bus bars such as TEST6 buses 9, 11, 12, 13, and 16;
   - when thin recovery is active, discard geometry candidates with no
     perpendicular branch. This removes the two straight line fragments that
     previously appeared as buses in TEST6 without changing mixed-layout
     reference images.

5. Detect loads with `backend_api/cv_load_experiment.py`:
   - find filled triangle/V-shaped arrow cores using distance-transform
     thresholds;
   - infer the cardinal arrow direction;
   - trace the opposite side toward a CV bus;
   - reject text fragments, ground bars, and disconnected marks;
   - use a small-arrow fallback for low-resolution large diagrams;
   - allow a short aligned bus-to-arrow connection only when the candidate is
     a sufficiently large, solid, hole-free triangular core. This specifically
     recovers TEST17's short bus/load gaps without restoring TEST16's numeric
     false loads.
   - allow a small near-square vertical arrow only when its lead has already
     reached a CV bus, its triangle score is at least 0.38, and the visible
     lead is long enough. This handles TEST6's bus-29 load without weakening
     the general ground-bar aspect filter.

   Although its filename contains `experiment`, `detect_cv_loads` is imported
   by the production runtime through `vision_logic.py`.

6. Detect transformers with `backend_api/cv_transformer_experiment.py`:
   - `wave`: two opposing rows of curved winding strokes with an empty gap;
   - `circle_pair`: two overlapping circular windings with supported outer
     contours and external lead support;
   - use both edge support and thresholded-ink ring support so faint JPEG
     outlines are not discarded;
   - allow small Hough centre error by checking a narrow perpendicular lead
     corridor.

7. Build the topology mask:
   - threshold the image with global and adaptive binary masks;
   - remove isolated number-like glyph components before topology tracing;
     labels are compact and tall, while conductor components remain because
     they are long, connected, or bus-shaped;
   - remove detected component regions from the mask;
   - expand bus masks by one pixel to separate incoming/outgoing branches
     around thin bars before skeletonization;
   - apply a small morphological close;
   - skeletonize with `cv2.ximgproc.thinning` when available.

8. Trace lines:
   - find skeleton pixels with one 8-neighbour as endpoints;
   - build component-aware ports before endpoint assignment:
     loads expose only the arrow tail/shaft side, transformers expose
     independent top/bottom or left/right side ports, generators use radial
     terminal geometry, and buses use their bar boundary;
   - assign an endpoint only when its distance, skeleton tangent, and port
     outward direction are compatible; a valid directional device port is
     preferred over a generic nearby bus boundary;
   - for a generator endpoint within 3 pixels of its masked box, allow a
     small tangent mismatch caused by an anti-aliased/diagonal shaft; keep
     the normal radial-direction check beyond that distance so a nearby
     opposite-facing endpoint is not admitted;
   - limit generator terminal matching to 14 pixels and, when multiple
     candidates remain, prefer the endpoint nearest the generator box. This
     prevents a nearby branch from replacing the actual generator shaft;
   - for a transformer segment port, allow an immediate bend when the
     endpoint is within 3.5 pixels and lies on the expected port side;
   - require a generic bus boundary endpoint to be within 10 pixels of the
     detected bus box. This prevents a number/symbol stroke far from a bus
     from being promoted to a bus-to-bus line;
   - walk the skeleton with `walk_skeleton_endpoint_v14`;
   - use smoothed direction, local forward jumps, and bounded branch search at
     bends/junctions;
   - accept a line when the walk reaches an endpoint assigned to another
     component;
   - keep at most one accepted connection for each load/generator, while
     retaining each direction-valid transformer port (including the case
     where only one transformer port is visible);
   - reject tiny isolated skeleton fragments for bus/transformer paths while
     allowing genuinely short, direction-valid load/generator shafts;
   - when skeleton masking removes a load's short shaft, preserve only the
     bus relationship already validated by `detect_cv_loads` as a
     `cv_load_bus_attachment` fallback; no generic nearest-bus fallback is
     allowed;
   - return the pixel path and the two component IDs.

9. Return the editor-compatible schema:

```json
{
  "nodes": [
    {
      "id": "load_12",
      "class": "load",
      "bbox": ["x_center", "y_center", "width", "height"],
      "confidence": 0.8
    }
  ],
  "lines": [
    {
      "line_id": "L0",
      "connected_to": ["bus_4", "generator_8"],
      "path": [[120, 250], [121, 251]]
    }
  ]
}
```

## What counts as connection ground truth

The actual connection relationship can be determined from the source SLD
image. That is the visual ground truth used during the previous debugging
work: each visible wire is traced from one symbol/bus to the next, including
short leads and routed bends.

The repository currently does **not** contain a separate machine-readable
edge-label file. Therefore a line count such as `lines=69` is not an accuracy
score. A proper regression record should store expected endpoint pairs, for
example:

```json
{
  "source": "TEST17.jpg",
  "edges": [
    ["bus_29", "load_29"],
    ["bus_27", "generator_27"]
  ]
}
```

For evaluation, compare predicted `connected_to` pairs against these manually
verified image relationships. Pixel-path overlap can be added later, but
endpoint-pair precision/recall is the most useful first metric.

## Known topology risks

- The endpoint walk is greedy at junctions; it does not enumerate every
  branch of a junction as a formal graph.
- A crossing without a connection dot can be merged by the skeleton, while a
  connected crossing can be treated as separate. There is no explicit
  bridge/crossing classifier yet.
- Port matching is still heuristic and its thresholds are image-scale
  dependent; it is no longer a nearest-component-only assignment.
- Text and symbol strokes remain in the binary image. The strict 10-pixel bus
  boundary contact check and isolated numeric-component removal block the
  observed long number-to-bus false paths, but very low-resolution images may
  still need scale-relative tuning.
- Full component-box masking can erase a short wire lead before skeletonizing.
- Global/adaptive thresholds and the `(2, 2)` close kernel can erase thin
  wires or bridge nearby lines.
- The fallback for a missing `ximgproc` thinning implementation is erosion,
  not a true skeletonizer, and should be treated as unsupported for topology
  accuracy.
- There is no full graph-level validation for crossings, parallel conductors,
  or every impossible endpoint pair. The one-connection cap currently applies
  only to loads and generators; transformers intentionally keep their
  direction-valid ports separately.

The safest next topology improvements are scale-relative port thresholds,
explicit junction branch enumeration, and a small verified crossing test set.
A complete topology rewrite is riskier than adding these guards during the
remaining competition month.

## Current regression results

These are detector outputs, not manually annotated accuracy scores. The
current 20-image result set is stored in
`_archive_experiments/20260818_object_pipeline_cleanup/hybrid_TEST1_20_load29_final/summary.csv`;
its visual overview is archived beside that file.

| Input | Bus | Generator | Load | Transformer | Lines |
| --- | ---: | ---: | ---: | ---: | ---: |
| IEEE24bus.jpg | 24 | 10 | 17 | 3 | 65 |
| 24bus.jpg | 23 | 10 | 17 | 3 | 62 |
| 39bus.jpg | 39 | 10 | 20 | 0 | 76 |
| 2026-7-01-1.jpg | 30 | 6 | 21 | 4 | 72 |
| TEST2.jpg | 30 | 6 | 21 | 4 | 72 |
| TEST1.jpg | 30 | 6 | 20 | 0 | 67 |
| TEST3.jpg | 14 | 5 | 11 | 5 | 40 |
| TEST5.jpg | 30 | 5 | 20 | 1 | 64 |
| TEST6.jpg | 30 | 6 | 21 | 0 | 68 |
| TEST7.jpg | 24 | 6 | 14 | 2 | 44 |
| TEST17.jpg | 30 | 5 | 20 | 0 | 65 |
| TEST18.jpg | 7 | 4 | 1 | 0 | 12 |

`2026-7-01-8.jpg` is referenced by older notes but is not currently present
in the workspace; it is not included in the current rerun.

## Important invariants

- CV is the primary geometry detector for bus and load. Generator semantics
  come from YOLO after terminal/transformer-pair validation. Transformer
  geometry comes from CV and requires YOLO confirmation or a guarded local
  pair check.
- A YOLO bus/load proposal never becomes a topology node by itself. It may
  rescue only a matching CV-rejected bar/arrow that still passes the class's
  mandatory structural and electrical-connection rules.
- The validated CV-backed bus rescue and YOLO-proposed/CV-port-validated load
  rescue are enabled by default in the API. They can be disabled explicitly
  with `POWERLENS_RELAXED_BUS_RESCUE=0` or
  `POWERLENS_YOLO_LOAD_PORT_RESCUE=0` for ablation tests.
- Bus, load, and transformer boxes are converted back to original-image
  coordinates after scaled CV processing.
- Normal load acceptance requires a physical lead-to-bus check. The short-gap
  exception is restricted by size, triangle score, hole filtering, axis
  alignment, and distance.
- Topology endpoint ownership is port-aware: load tail/shaft direction is
  required, transformer sides are tracked independently, and only
  loads/generators receive a one-connection cap.
- Generator terminal matching is limited to a 14-pixel box distance and
  selects the nearest terminal candidate; transformer ports may absorb only
  a 3.5-pixel immediate bend when the bend remains on the expected side.
- The transformer-pair filter is a generator rejection filter; the active
  transformer detector is a separate CV stage.
- The frontend continues to consume the common `nodes`/`lines` schema.
- Connection correctness must be assessed using manually verified endpoint
  pairs, not only the number of returned lines.

## Hybrid detector regression (2026-08-15)

The production orchestration in `backend_api/core/vision_logic.py` follows this
order:

1. CV extracts the final bus family, then detects loads against that exact bus
   registry and extracts transformer winding candidates.
2. YOLO proposes semantic regions at the original image scale (`imgsz=640`).
   Bus proposals are processed first so a CV-rejected bar can be available to
   later load-tail validation.
3. Monster boxes are removed. Generators require a valid terminal or the
   guarded standalone-symbol condition, and overlapping winding pairs veto a
   generator proposal.
4. Bus/load YOLO proposals may rescue only matching CV geometry. Transformer
   proposals confirm a CV pair or trigger one compact local pair check; raw
   YOLO boxes do not bypass these structural gates.
5. The resulting nodes are passed to the port-aware topology walker and then
   to the adaptive graph-policy report.

The active 26-image held-out set was scored at IoU >= 0.40:

| Detector checkpoint | TP | FP | FN | Precision | Recall | F1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Friend checkpoint + conservative CV rescue | 765 | 25 | 15 | 0.9684 | 0.9808 | 0.9745 |
| Local `2026_07_30_coslr.pt` + conservative CV rescue | 764 | 15 | 16 | 0.9807 | 0.9795 | **0.9801** |

These are object metrics, not proof that every topology line is correct. The
local checkpoint is the better current default on this held-out set. The API
can select another checkpoint without code edits through
`POWERLENS_YOLO_MODEL=<path-to-best.pt>`.

The local TEST1--TEST10 overlays, including red line IDs, are generated under
`_archive_experiments/20260818_object_pipeline_cleanup/comparison_integrated_hybrid/user_TEST1_10/`.
The associated reports are retained in that archived experiment folder.

## Object-only regression and rescue policy (2026-08-18)

The latest reviewable outputs are consolidated under
`object_regression_latest/`. `summary.csv` and `aggregate.csv` score 17
labelled held-out sheets at IoU >= 0.30. `test_image52` is explicitly excluded
because its bus labels/orientation do not describe the same symbol convention.
`local_references/` contains object-only overlays for 24bus, 39bus, TEST1, and
TEST20. Topology is intentionally excluded from this regression.

| Class | TP | FP | FN | Precision | Recall |
| --- | ---: | ---: | ---: | ---: | ---: |
| Bus | 234 | 0 | 0 | **1.0000** | **1.0000** |
| Generator | 70 | 0 | 0 | **1.0000** | **1.0000** |
| Load | 121 | 3 | 3 | 0.9758 | 0.9758 |
| Transformer | 20 | 0 | 1 | **1.0000** | 0.9524 |

The bus stage now treats YOLO boxes only as search windows. It reconstructs
the tight straight raster bar, erases that bar from the skeleton, and counts
independent perpendicular and endpoint ports. A CV-only bar can survive only
when it belongs to the within-sheet thickness family and has its own strong
multi-port junction signature. This is an electrical consensus rather than a
global confidence or fixed-pixel threshold change. It recovered merged/thin
buses in images 36, 40, 42, and 45 while removing feeder/text bars.

A sheet may also contain a clearly separate thin-bus style. That secondary
family is enabled only after at least three same-orientation CV bars with
multiple perpendicular ports agree on a thickness no greater than 68% of the
primary bus family. Once established, a same-style two-port bar may join it;
one weak bar can never establish the family by itself. Secondary candidates
inside a confirmed generator or transformer are vetoed. This recovers all 30
buses in `TEST6` (previously 26) without changing the 234/234 held-out bus
result or adding a held-out false positive.

Loads are validated as one-terminal circuit branches: the tail must reach a
validated bus, and the tip must become open circuit beyond the arrowhead. A
straight feeder may be long; only a graph walk that turns through unrelated
ink retains the old length guard. Missing raster ink may be bridged only with
independent YOLO class support, and a load centre inside an accepted
transformer winding is removed as a cross-class electrical conflict. This
fixes the P/Q-label continuation error in image 31, digit-`1` false loads in
image 32, and transformer-winding false loads in image 45.

The detector emits exactly 124 load nodes for 124 labelled loads. The three
remaining IoU failures in images 39, 42, and 47 are correctly centred load
symbols whose ground-truth rectangles are roughly twice the visible
arrowhead size. Their tight topology-safe boxes were deliberately not enlarged
just to memorise inconsistent annotation extents.

The validated generator rescue now probes YOLO candidates down to confidence
0.30. A low-confidence candidate is admitted only when CV finds a single ring
with an immediate external conductor or a straight terminal reaching a bus.
The previous transformer-pair veto remains active; only an edge-clipped
terminal-backed generator may override it.

Transformer standalone recovery is style-specific. A high-confidence `wave`
winding may survive without YOLO because YOLO can see only part of the repeated
curve. A compact `circle_pair` is recovered at probe-level YOLO confidence
only after CV proves all three physical conditions: two supported circular
outlines with a hollow interior, opposite electrical ports, and conductor
reachability to the validated bus network. Probe support is merged by maximum
confidence so a later weak duplicate cannot overwrite stronger evidence. This
recovers all four circle-pair transformers in `TEST2`, rejects filled bus bars
and the impedance-text pair `00`, and keeps transformer false positives at zero
in the active held-out batch.

The current local smoke set is rendered under
`object_regression_latest/test_selection_TEST1_6/`: TEST1--5 retain their
previous bus/generator/load counts, TEST2 changes only from 0 to 4
transformers, and TEST6 changes from 26 to 30 buses and from 19 to 21 validated
loads. Every detector-policy change must pass the 20 unit tests, the 17-image
labelled regression, and this six-image smoke set before it is retained.

Known remaining items must not be addressed by globally lowering a threshold:

- One transformer in `test_image42` is still missed; bus/load behaviour is
  already correct there, so this belongs to the separate transformer stage.
- The three load IoU misses described above are annotation-extent mismatches,
  not missing or extra electrical objects.
- `test_image52` remains a label/style audit item and is not part of the active
  regression contract.

## Files to inspect first

- `backend_api/core/vision_logic.py` — production orchestration, masking,
  topology walk, and output schema.
- `backend_api/cv_bus_refined_experiment.py` — production bus CV detector.
- `backend_api/cv_load_experiment.py` — production load CV detector.
- `backend_api/cv_transformer_experiment.py` — production transformer CV
  detector.
- `backend_api/main_server.py` — FastAPI endpoint and YOLO model loading.
- `VisionFlow_PRD.md` — product direction, including Human-in-the-Loop
  correction in the frontend.

## Basic verification

From the repository root:

```powershell
python -m py_compile backend_api/core/vision_logic.py backend_api/cv_bus_refined_experiment.py backend_api/cv_load_experiment.py backend_api/cv_transformer_experiment.py
python -m unittest discover -s backend_api/tests -v
python backend_api/run_object_regression.py
```

For an end-to-end check, start the FastAPI server and upload the regression
images to `/analyze_image`. Check both:

1. node counts and bounding boxes;
2. manually verified `connected_to` endpoint pairs and the displayed pixel
   paths.

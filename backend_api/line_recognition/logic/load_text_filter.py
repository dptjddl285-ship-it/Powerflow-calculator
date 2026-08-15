"""Image-only second-stage filter for YOLO Load proposals.

The serialized classifier is trained offline from Train crops.  At inference
this module receives only the image pixels and an already-predicted box; it
does not receive image names, annotations, or ground-truth coordinates.
"""

from pathlib import Path

import cv2
import joblib
import numpy as np


MODEL_PATH = Path(__file__).resolve().parents[2] / "icon_recognition" / "models" / "load_text_filter.joblib"
# Learned-crop margin: Train ablation has Load minimum 0.733 and the closest
# text false positive 0.606, leaving a conservative gap at 0.65.
DECISION_THRESHOLD = 0.65
_classifier = None


def hog_feature(gray):
    """Return a fixed HOG descriptor for a proposed small symbol crop."""
    resized = cv2.resize(gray, (32, 32), interpolation=cv2.INTER_AREA)
    descriptor = cv2.HOGDescriptor((32, 32), (16, 16), (8, 8), (8, 8), 9)
    return descriptor.compute(resized).ravel()


def _load_classifier():
    global _classifier
    if _classifier is None and MODEL_PATH.exists():
        _classifier = joblib.load(MODEL_PATH)
    return _classifier


def is_load_symbol(bgr_image, bbox):
    """Return True when the crop is accepted as a Load-like symbol.

    Missing model files fail open so normal detection remains usable until the
    explicitly trained artifact is present.
    """
    classifier = _load_classifier()
    if classifier is None:
        return True
    center_x, center_y, width, height = map(float, bbox)
    image_height, image_width = bgr_image.shape[:2]
    x1 = max(0, int(center_x - width / 2))
    y1 = max(0, int(center_y - height / 2))
    x2 = min(image_width, int(center_x + width / 2))
    y2 = min(image_height, int(center_y + height / 2))
    if x2 <= x1 or y2 <= y1:
        return False
    gray = cv2.cvtColor(bgr_image[y1:y2, x1:x2], cv2.COLOR_BGR2GRAY)
    score = float(classifier.decision_function([hog_feature(gray)])[0])
    return score >= DECISION_THRESHOLD

"""Deterministic Evidence Extractor and Suspicious Classifier for VisionFlow SLD Objects."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


@dataclass
class ObjectEvidence:
    node_id: str
    class_name: str
    bbox: List[float]  # [cx, cy, w, h] in original pixel coordinates
    confidence: float
    source: str
    yolo_support: float = 0.0
    policy_decision: str = "ACCEPT"  # ACCEPT, REVIEW, RESCUE, REJECT
    policy_reasons: List[str] = field(default_factory=list)
    geometry_evidence: Dict[str, Any] = field(default_factory=dict)
    is_suspicious: bool = False
    suspicious_reasons: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "node_id": self.node_id,
            "class": self.class_name,
            "bbox": self.bbox,
            "confidence": self.confidence,
            "source": self.source,
            "yolo_support": self.yolo_support,
            "policy_decision": self.policy_decision,
            "policy_reasons": self.policy_reasons,
            "geometry_evidence": self.geometry_evidence,
            "is_suspicious": self.is_suspicious,
            "suspicious_reasons": self.suspicious_reasons,
        }


# Thresholds for deterministic suspicious classification (optimized to avoid excessive flags)
CONFIDENCE_THRESHOLDS = {
    "bus": 0.60,
    "generator": 0.55,
    "load": 0.50,
    "transformer": 0.50,
}

RESCUE_SOURCES = {
    "yolo_port_rescue",
    "yolo_bus_rescue",
    "yolo_generator_rescue",
    "cv_fallback",
    "ambiguous_rescue",
}


def _calculate_iou(box1: List[float], box2: List[float]) -> float:
    """Calculate IoU for two bounding boxes in [cx, cy, w, h] format."""
    x1_min = box1[0] - box1[2] / 2.0
    y1_min = box1[1] - box1[3] / 2.0
    x1_max = box1[0] + box1[2] / 2.0
    y1_max = box1[1] + box1[3] / 2.0

    x2_min = box2[0] - box2[2] / 2.0
    y2_min = box2[1] - box2[3] / 2.0
    x2_max = box2[0] + box2[2] / 2.0
    y2_max = box2[1] + box2[3] / 2.0

    inter_xmin = max(x1_min, x2_min)
    inter_ymin = max(y1_min, y2_min)
    inter_xmax = min(x1_max, x2_max)
    inter_ymax = min(y1_max, y2_max)

    inter_width = max(0.0, inter_xmax - inter_xmin)
    inter_height = max(0.0, inter_ymax - inter_ymin)
    inter_area = inter_width * inter_height

    area1 = box1[2] * box1[3]
    area2 = box2[2] * box2[3]
    union_area = area1 + area2 - inter_area
    if union_area <= 0:
        return 0.0
    return inter_area / union_area


def extract_object_evidence(node: Dict[str, Any], all_nodes: Optional[List[Dict[str, Any]]] = None) -> ObjectEvidence:
    """Extract structured evidence from a detection node."""
    node_id = str(node.get("id", ""))
    class_name = str(node.get("class", node.get("class_name", "unknown"))).lower()
    bbox = [float(v) for v in node.get("bbox", [0.0, 0.0, 10.0, 10.0])]
    confidence = float(node.get("confidence", 0.0))
    source = str(node.get("source", "unknown"))
    yolo_support = float(node.get("yolo_support", confidence if "yolo" in source else 0.0))
    metadata = node.get("metadata", {})

    policy_reasons: List[str] = []
    suspicious_reasons: List[str] = []
    geometry_evidence: Dict[str, Any] = {}

    # 1. Low Confidence check
    min_conf = CONFIDENCE_THRESHOLDS.get(class_name, 0.65)
    if confidence < min_conf:
        policy_reasons.append(f"Low confidence ({confidence:.2f} < {min_conf:.2f})")
        suspicious_reasons.append(f"AI 신뢰도가 기준치({min_conf:.2f})보다 낮음 ({confidence:.2f})")

    # 2. Rescue Source check
    if source in RESCUE_SOURCES or "rescue" in source:
        policy_reasons.append(f"Rescued candidate from source '{source}'")
        suspicious_reasons.append("단일 모델에서 확신하지 못해 구조(Rescue) 규칙으로 추가된 후보")

    # 3. Geometry Aspect Ratio check
    w, h = bbox[2], bbox[3]
    geometry_evidence["width"] = w
    geometry_evidence["height"] = h
    geometry_evidence["aspect_ratio"] = max(w, h) / max(min(w, h), 1e-4)

    if class_name == "bus":
        aspect = geometry_evidence["aspect_ratio"]
        if aspect < 2.0:
            policy_reasons.append(f"Bus aspect ratio is low ({aspect:.1f})")
            suspicious_reasons.append(f"Bus 형태이나 가로/세로 비율({aspect:.1f})이 일반적인 모선보다 짧음")
    elif class_name in ("generator", "transformer"):
        aspect = geometry_evidence["aspect_ratio"]
        if aspect > 2.5:
            policy_reasons.append(f"Device aspect ratio is high ({aspect:.1f})")
            suspicious_reasons.append(f"{class_name.capitalize()} 후보이나 가로/세로 비율이 비정상적으로 길쭉함")

    # 4. Overlap / Conflict check with other nodes
    if all_nodes:
        for other in all_nodes:
            other_id = str(other.get("id", ""))
            if other_id == node_id:
                continue
            other_box = other.get("bbox", [0.0, 0.0, 0.0, 0.0])
            iou = _calculate_iou(bbox, other_box)
            if iou > 0.35:
                other_class = other.get("class", "")
                policy_reasons.append(f"Overlap with {other_id} ({other_class}, IoU={iou:.2f})")
                suspicious_reasons.append(f"다른 객체({other_id}, {other_class})와 영역이 과도하게 중첩됨 (IoU={iou:.2f})")

    # 5. Metadata-based evidence
    if "load_candidate" in metadata:
        geometry_evidence["has_cv_lead"] = True
    if "transformer" in metadata:
        geometry_evidence["transformer_orientation"] = metadata.get("transformer", {}).get("orientation")

    is_suspicious = len(suspicious_reasons) > 0
    policy_decision = "REVIEW" if is_suspicious else "ACCEPT"

    return ObjectEvidence(
        node_id=node_id,
        class_name=class_name,
        bbox=bbox,
        confidence=confidence,
        source=source,
        yolo_support=yolo_support,
        policy_decision=policy_decision,
        policy_reasons=policy_reasons,
        geometry_evidence=geometry_evidence,
        is_suspicious=is_suspicious,
        suspicious_reasons=suspicious_reasons,
    )


def classify_suspicious(nodes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Process a list of detection nodes and annotate each with review status and reasons."""
    annotated: List[Dict[str, Any]] = []
    for node in nodes:
        evidence = extract_object_evidence(node, all_nodes=nodes)
        node_copy = dict(node)
        node_copy["review_status"] = "SUSPICIOUS" if evidence.is_suspicious else "DETECTED"
        node_copy["review_reasons"] = evidence.suspicious_reasons
        node_copy["evidence"] = evidence.to_dict()
        annotated.append(node_copy)
    return annotated

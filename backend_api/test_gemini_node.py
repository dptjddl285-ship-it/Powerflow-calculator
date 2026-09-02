"""Test Gemini Object Reviewer."""

from __future__ import annotations

import sys
from pathlib import Path

backend_root = Path(__file__).resolve().parent
if str(backend_root) not in sys.path:
    sys.path.insert(0, str(backend_root))

import core.env_loader
from agent.evidence_extractor import ObjectEvidence
from agent.object_reviewer import object_reviewer

evidence = ObjectEvidence(
    node_id="bus_0",
    class_name="bus",
    confidence=0.72,
    bbox=[100.0, 50.0, 120.0, 15.0],
    source="yolo_primary",
    is_suspicious=True,
    suspicious_reasons=["모선 종횡비(W/H) 기준 하한선 근접"],
)

print(f"Testing Gemini Object Review for: {evidence.node_id} ({evidence.class_name})...")
result = object_reviewer.review_object(evidence)

print("\n--- Object Review Result ---")
print(f"Agent Status: {result.agent_status}")
print(f"Assessment: {result.assessment}")
print(f"Message (KO): {result.message_ko}")
print(f"Recommended Action: {result.recommended_action}")
print(f"Suggested Classes: {result.suggested_classes}")

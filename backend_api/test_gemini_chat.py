"""Test GeminiReviewAssistantProvider with the user's diagram question."""

from __future__ import annotations

import sys
from pathlib import Path

backend_root = Path(__file__).resolve().parent
if str(backend_root) not in sys.path:
    sys.path.insert(0, str(backend_root))

import core.env_loader
from agent.providers import get_assistant_provider

provider = get_assistant_provider()
print(f"Active Provider: {provider.display_mode_name} ({provider.provider_name})")

sample_nodes = [
    {"id": "bus_0", "class": "bus", "display_label": "BUS 8", "review_status": "DETECTED", "confidence": 0.90},
    {"id": "bus_1", "class": "bus", "display_label": "BUS 1", "review_status": "DETECTED", "confidence": 0.95},
    {"id": "gen_0", "class": "generator", "display_label": "GEN 1", "review_status": "DETECTED", "confidence": 0.92},
    {"id": "load_0", "class": "load", "display_label": "LOAD 1", "review_status": "DETECTED", "confidence": 0.88},
]

sample_lines = [
    {"line_id": "L1", "connected_to": ["bus_0", "bus_1"], "review_status": "DETECTED"},
    {"line_id": "L2", "connected_to": ["gen_0", "bus_1"], "review_status": "DETECTED"},
    {"line_id": "L3", "connected_to": ["load_0", "bus_0"], "review_status": "DETECTED"},
]

query = "변압기 없는건 문제 안되나 지금 회로도에서?"
print(f"\nUser Query: {query}")

response = provider.answer_chat(
    message=query,
    document_id="doc_test_123",
    stage="OBJECT_REVIEW",
    selected_node=sample_nodes[0],
    working_nodes=sample_nodes,
    working_lines=sample_lines,
    missing_candidates=[],
    topology_issues=[],
)

print("\n--- Gemini AI Response ---")
print(f"Status: {response.get('agent_status')}")
print(f"Reply:\n{response.get('reply_ko')}")

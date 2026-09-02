"""Test Multimodal Gemini Assistant with session image."""

from __future__ import annotations

import sys
from pathlib import Path

backend_root = Path(__file__).resolve().parent
if str(backend_root) not in sys.path:
    sys.path.insert(0, str(backend_root))

import cv2
import numpy as np
import core.env_loader
from agent.providers import get_assistant_provider
from review.session_store import session_store

# Create a sample test image with a circle (generator) and text
img = np.ones((400, 400, 3), dtype=np.uint8) * 255
cv2.circle(img, (200, 200), 50, (0, 0, 0), 2)
cv2.putText(img, "GEN-100", (160, 205), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 2)
_, img_bytes = cv2.imencode(".png", img)

# Save in session_store
session = session_store.create_session(img_bytes.tobytes(), "image/png")
doc_id = session.document_id

provider = get_assistant_provider()
print(f"Provider: {provider.display_mode_name}")

query = "도면 중앙에 그려진 기호와 기호 안에 적힌 글자가 뭐야?"
print(f"User Query: {query}")

res = provider.answer_chat(
    message=query,
    document_id=doc_id,
    stage="OBJECT_REVIEW",
    working_nodes=[],
    working_lines=[],
)

print("\n--- Gemini Multimodal Vision Response ---")
print("Status:", res.get("agent_status"))
print("Reply:\n", res.get("reply_ko"))

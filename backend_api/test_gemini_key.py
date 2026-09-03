"""Test Gemini API key connectivity and generation."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

backend_root = Path(__file__).resolve().parent
if str(backend_root) not in sys.path:
    sys.path.insert(0, str(backend_root))

import core.env_loader

api_key = os.environ.get("GEMINI_API_KEY", "").strip()

print(f"Loaded GEMINI_API_KEY: {api_key[:8]}...{api_key[-6:]}")

test_models = [
    "gemini-3.5-flash",
    "gemini-3.5-flash-lite",
    "gemini-3.1-flash-lite",
    "gemini-3.7-flash",
    "gemini-3.6-flash",
    "gemini-flash-lite-latest",
]

import base64

print("\n" + "="*60)
print(" [Testing Gemini Multimodal Vision on 1_Original.jpg]")
print("="*60)

import cv2
import numpy as np
from ultralytics import YOLO
from core.adaptive_vision_pipeline import detect_sld_objects_adaptive

# 1. Load image and get CV buses
img_path = Path(__file__).resolve().parent.parent / "학습 IEEE" / "1_Original.jpg"
if not img_path.exists():
    img_path = Path(__file__).resolve().parent / "models" / "IEEE24bus.jpg"

with open(img_path, "rb") as f:
    img_bytes = f.read()

img = cv2.imdecode(np.frombuffer(img_bytes, np.uint8), cv2.IMREAD_COLOR)
h_img, w_img = img.shape[:2]

model = YOLO(str(Path(__file__).resolve().parent / "models" / "2026_07_30_coslr.pt"))
res = detect_sld_objects_adaptive(img_bytes, model)
buses = [n for n in res.get("nodes", []) if (n.get("class") or n.get("class_name") or "").lower() == "bus"]

buses_summary = []
for idx, b in enumerate(buses):
    cx, cy, w, h = b["bbox"]
    buses_summary.append({
        "id": f"bus_{idx}",
        "x": round(cx / w_img, 3),
        "y": round(cy / h_img, 3)
    })

# 2. Ask Gemini 3.5 Flash
b64_img = base64.b64encode(img_bytes).decode("utf-8")
prompt = (
    f"You are an electrical engineering power flow expert.\n"
    f"Here is a single-line diagram of the standard IEEE 24-bus power system.\n"
    f"We detected {len(buses)} Bus Bars with normalized coordinates [x: 0~1 (left to right), y: 0~1 (top to bottom)]:\n"
    f"{json.dumps(buses_summary)}\n\n"
    f"Please inspect the diagram, look at the printed numbers (1 to 24) and their positions.\n"
    f"Map each bus id to its exact integer bus number (1 to 24).\n"
    f"Return a strict JSON dictionary: {{\"bus_0\": 18, \"bus_1\": 21, ...}}"
)

url_gen = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent?key={api_key}"
payload = {
    "contents": [{
        "parts": [
            {"text": prompt},
            {"inlineData": {"mimeType": "image/jpeg", "data": b64_img}}
        ]
    }],
    "generationConfig": {"responseMimeType": "application/json"}
}

req = urllib.request.Request(
    url_gen,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST"
)

try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        reply_text = data["candidates"][0]["content"]["parts"][0]["text"]
        mapping = json.loads(reply_text)
        print("\n[Gemini 3.5 Flash Bus Mapping Result]:")
        for k, v in mapping.items():
            print(f"  {k} -> Bus #{v}")
            
        annotated = img.copy()
        for idx, b in enumerate(buses):
            bid = f"bus_{idx}"
            assigned_num = mapping.get(bid)
            cx, cy, w, h = b["bbox"]
            x1, y1 = int(cx - w/2), int(cy - h/2)
            x2, y2 = int(cx + w/2), int(cy + h/2)
            cv2.rectangle(annotated, (x1, y1), (x2, y2), (255, 120, 0), 2)
            label = f"#{assigned_num}" if assigned_num is not None else "?"
            cv2.putText(annotated, label, (x1, max(18, y1 - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 200, 0), 2)
            
        out_path = Path(__file__).resolve().parent / "1_original_gemini_vision_result.jpg"
        cv2.imwrite(str(out_path), annotated)
        print(f"\n[Saved Annotated Image]: {out_path}")
except Exception as e:
    print(f"Gemini Vision Error: {e}")

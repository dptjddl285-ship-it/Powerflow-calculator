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

for model_name in test_models:
    print(f"\n[Testing Model: {model_name}]")
    url_gen = f"https://generativelanguage.googleapis.com/v1beta/models/{model_name}:generateContent?key={api_key}"
    payload = {
        "contents": [{
            "parts": [{"text": "Hello, respond with: 'PowerLens Gemini API is connected!'"}]
        }]
    }
    req_gen = urllib.request.Request(
        url_gen,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req_gen, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            candidates = data.get("candidates", [])
            if candidates:
                reply = candidates[0].get("content", {}).get("parts", [{}])[0].get("text", "")
                print(f"[SUCCESS] {model_name} responded:")
                print(f"  {reply.strip()}")
                print("\n>>> ALL TESTS PASSED! API KEY IS 100% VALID AND OPERATIONAL! <<<")
                break
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        print(f"[FAILED] {model_name} (HTTP {e.code}): {err_body[:160]}")
    except Exception as e:
        print(f"[ERROR] {model_name}: {e}")
    time.sleep(1)

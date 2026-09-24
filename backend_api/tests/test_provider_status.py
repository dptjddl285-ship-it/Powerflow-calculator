import asyncio
import sys
from pathlib import Path

backend_api_dir = Path(__file__).resolve().parent.parent
if str(backend_api_dir) not in sys.path:
    sys.path.insert(0, str(backend_api_dir))

from review import staged_api


class _GeminiProvider:
    provider_name = "gemini"
    display_mode_name = "Gemini"
    primary_model_name = "gemini-primary-test"
    fallback_model_name = "gemini-fallback-test"


class _LocalProvider:
    provider_name = "local"
    display_mode_name = "Local deterministic"


def test_gemini_provider_status_includes_models_without_secrets(monkeypatch):
    monkeypatch.setattr(staged_api, "get_assistant_provider", lambda: _GeminiProvider())

    response = asyncio.run(staged_api.review_provider_status())

    assert response == {
        "status": "ok",
        "provider_mode": "gemini",
        "display_mode": "Gemini",
        "primary_model": "gemini-primary-test",
        "fallback_model": "gemini-fallback-test",
        "fallback_configured": True,
    }
    assert "api_key" not in response


def test_local_provider_status_does_not_claim_gemini_models(monkeypatch):
    monkeypatch.setattr(staged_api, "get_assistant_provider", lambda: _LocalProvider())

    response = asyncio.run(staged_api.review_provider_status())

    assert response["provider_mode"] == "local"
    assert "primary_model" not in response
    assert "fallback_model" not in response

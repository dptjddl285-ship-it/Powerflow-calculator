"""Centralized Gemini Model Configuration for PowerLens.

Provides a single source of truth for Gemini primary and fallback model names.
Avoids hardcoding model strings across different agent/core modules.
"""
from __future__ import annotations

import os
from .env_loader import load_env

load_env()

DEFAULT_GEMINI_PRIMARY_MODEL = "gemini-3.8-flash"
DEFAULT_GEMINI_MODEL = DEFAULT_GEMINI_PRIMARY_MODEL
DEFAULT_GEMINI_FALLBACK_MODEL = "gemini-3.6-flash"


def get_gemini_model_name() -> str:
    """Return the configured primary Gemini model name (default: gemini-3.8-flash)."""
    val = (os.environ.get("GEMINI_MODEL") or DEFAULT_GEMINI_PRIMARY_MODEL).strip()
    return val if val else DEFAULT_GEMINI_PRIMARY_MODEL


def get_gemini_fallback_model_name() -> str:
    """Return the configured fallback Gemini model name (default: gemini-3.6-flash)."""
    val = (os.environ.get("GEMINI_FALLBACK_MODEL") or DEFAULT_GEMINI_FALLBACK_MODEL).strip()
    return val if val else DEFAULT_GEMINI_FALLBACK_MODEL

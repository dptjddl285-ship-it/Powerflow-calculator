"""Lightweight environment loader for PowerLens / VisionFlow.

Loads .env from the project root or backend_api directory if present,
populating os.environ without overwriting existing environment variables.
"""

from __future__ import annotations

import os
from pathlib import Path


def load_env(env_path: Path | str | None = None) -> dict[str, str]:
    """Load environment variables from .env file into os.environ."""
    loaded: dict[str, str] = {}
    candidates: list[Path] = []

    if env_path is not None:
        candidates.append(Path(env_path))
    else:
        current_dir = Path(__file__).resolve().parent
        candidates.extend([
            current_dir.parent / ".env",          # backend_api/.env
            current_dir.parent.parent / ".env",   # project_root/.env
            Path.cwd() / ".env",                  # cwd/.env
        ])

    target_file = None
    for candidate in candidates:
        if candidate.is_file():
            target_file = candidate
            break

    if target_file is None:
        return loaded

    try:
        content = target_file.read_text(encoding="utf-8")
    except Exception:
        return loaded

    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        if key and key not in os.environ:
            os.environ[key] = value
            loaded[key] = value

    return loaded


# Auto-load on import
load_env()

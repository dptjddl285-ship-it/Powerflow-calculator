"""PowerLens Pro - Backend Server Runner
Convenience launcher to run the FastAPI backend server.
"""
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
BACKEND_DIR = PROJECT_ROOT / "backend_api"

if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

if __name__ == "__main__":
    import uvicorn
    from main_server import app

    print("🚀 Starting PowerLens Pro Backend Server on http://127.0.0.1:8000...")
    uvicorn.run(app, host="127.0.0.1", port=8000)

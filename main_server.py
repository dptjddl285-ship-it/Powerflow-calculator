"""PowerLens Pro - Root Server Launcher
Convenience launcher to run the FastAPI backend server from the workspace root.
"""

import os
import sys

# Ensure backend_api directory is in sys.path
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
backend_dir = os.path.join(BASE_DIR, "backend_api")
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

if __name__ == "__main__":
    import uvicorn
    from backend_api.main_server import app

    print("🚀 Starting PowerLens Pro Backend Server on http://127.0.0.1:8000...")
    uvicorn.run(app, host="127.0.0.1", port=8000)


import http.server
import socketserver
import os
import sys

PORT = 58640
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(BASE_DIR, "frontend_app", "build", "web")

class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()

def main():
    socketserver.TCPServer.allow_reuse_address = True
    print(f"▶ [PowerLens] Serving frontend from: {WEB_DIR}")
    print(f"▶ [PowerLens] Frontend running at: http://localhost:{PORT} (Cache disabled)")
    with socketserver.TCPServer(("", PORT), NoCacheHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down server.")

if __name__ == '__main__':
    main()

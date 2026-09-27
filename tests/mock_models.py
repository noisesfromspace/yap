import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.path == "/v1/models", self.path
        assert self.headers["Authorization"] == "Bearer " + __import__("os").environ["MOONSHOT_API_KEY"]
        body = json.dumps({"data": [{"id": "m2"}, {"id": "m1"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 18137), H).serve_forever()

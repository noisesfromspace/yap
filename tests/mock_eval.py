import json
from http.server import BaseHTTPRequestHandler, HTTPServer

# One-shot eval mock: returns a fixed body and logs the provider request so
# the test can assert tools were not offered.
LOG = "/tmp/yap-eval.log"


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(LOG, "a") as f:
            f.write(json.dumps(body) + "\n")
        answer = "summarized output"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        chunk = json.dumps({"choices": [{"delta": {"content": answer}}]})
        self.wfile.write(("data: " + chunk + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", 18180), H).serve_forever()

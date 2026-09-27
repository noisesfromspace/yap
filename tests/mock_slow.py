import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for word in ["The ", "slow ", "answer ", "arrives ", "in ", "parts."]:
            chunk = {"choices": [{"delta": {"content": word}}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()
            time.sleep(0.4)
        usage = {"choices": [], "usage": {"prompt_tokens": 1500, "completion_tokens": 42}}
        self.wfile.write(b"data: " + json.dumps(usage).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 18132), H).serve_forever()

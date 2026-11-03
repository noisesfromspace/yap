import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        time.sleep(1.5)  # Give Ctrl-C time to arrive before any assistant output.
        try:
            chunk = {"choices": [{"delta": {"content": "late answer"}, "finish_reason": "stop"}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\ndata: [DONE]\n\n")
        except BrokenPipeError:
            pass

    def log_message(self, *args):
        pass

ThreadingHTTPServer(("127.0.0.1", 18165), H).serve_forever()

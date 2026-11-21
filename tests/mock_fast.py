import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Same stream as mock_slow.py ("The slow answer arrives in parts.") but with
# no per-chunk sleep: the fast tier's integration cases only need a completed
# turn, not a window in which to stop/steer/follow. Threaded because the fast
# tier runs several cases concurrently.

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for word in ["The ", "slow ", "answer ", "arrives ", "in ", "parts."]:
            chunk = {"choices": [{"delta": {"content": word}}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()
        usage = {"choices": [], "usage": {"prompt_tokens": 1500, "completion_tokens": 42}}
        self.wfile.write(b"data: " + json.dumps(usage).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass

ThreadingHTTPServer(("127.0.0.1", 18133), H).serve_forever()

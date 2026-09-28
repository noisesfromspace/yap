import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer

# Streams multi-line output slowly, so a window watching the end has to keep
# scrolling to keep up. One chunk (10) deliberately ends mid-line (no "\n"):
# that is the case where an append no longer lands exactly on the cursor, so
# the view used to stop following partway through a reply.
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for i in range(1, 31):
            text = "mid-line chunk without a newline" if i == 10 else "streamed line %d\n" % i
            chunk = {"choices": [{"delta": {"content": text}}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()
            time.sleep(0.1)
        usage = {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 30}}
        self.wfile.write(b"data: " + json.dumps(usage).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", 18152), H).serve_forever()

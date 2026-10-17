import json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Fork-while-running mock: streams newline-terminated lines slowly so the
# harness flushes each line into the buffer while the turn is still in
# flight (the ProseEscaper holds a partial line until its newline). The
# fork test waits for the first line, then forks before the stream ends.
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for line in [
            "The slow answer\n",
            "arrives in parts.\n",
            "It keeps streaming\n",
            "for a while so a\n",
            "fork can catch it\n",
            "mid-turn reliably.\n",
        ]:
            chunk = {"choices": [{"delta": {"content": line}}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()
            time.sleep(0.4)
        usage = {"choices": [], "usage": {"prompt_tokens": 1500, "completion_tokens": 42}}
        self.wfile.write(b"data: " + json.dumps(usage).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass

ThreadingHTTPServer(("127.0.0.1", 18164), H).serve_forever()

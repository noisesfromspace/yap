import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer

# Streams a reply slowly that mixes plain prose with a thinking block, so a
# window watching the end has to keep scrolling to keep up. One chunk (6)
# ends mid-line (no "\n") and the thinking block opens a comment on its own
# line: both move the stream tail without landing on the cursor, which is
# where a non-following window used to lose the end.
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def emit(kind, text):
            key = "reasoning_content" if kind == "thinking" else "content"
            chunk = {"choices": [{"delta": {key: text}}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()
            time.sleep(0.1)

        for i in range(1, 6):
            emit("text", "streamed line %d\n" % i)
        emit("text", "mid-line chunk without a newline")
        emit("thinking", "thinking about the answer\n")
        for i in range(7, 11):
            emit("text", "streamed line %d\n" % i)

        usage = {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 30}}
        self.wfile.write(b"data: " + json.dumps(usage).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", 18152), H).serve_forever()

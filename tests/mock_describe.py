import json
from http.server import BaseHTTPRequestHandler, HTTPServer

# Records every request's messages to a file so the Lua test can assert
# which model was asked for what (tiny user-message summary vs. the
# bigger whole-session summary). Answers "described." for everything.
LOG = "/tmp/yap-describe.log"


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(LOG, "a") as f:
            f.write(json.dumps(body["messages"]) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(b'data: {"choices": [{"delta": {"content": "described."}}]}\n\n')
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", 18139), H).serve_forever()

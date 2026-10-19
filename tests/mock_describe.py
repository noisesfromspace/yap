import json
from http.server import BaseHTTPRequestHandler, HTTPServer

# Records requests so the Lua test can assert title-generation context. A
# marked title request gets a fenced response to exercise the output guard, or
# a colon title to exercise the YAML-safe sanitizer.
LOG = "/tmp/yap-describe.log"


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body["messages"]
        with open(LOG, "a") as f:
            f.write(json.dumps(body) + "\n")
        is_title = any("Write a short session title" in m.get("content", "") for m in messages)
        has_fence_case = any("Fence regression trigger" in m.get("content", "") for m in messages)
        has_colon_case = any("Colon regression trigger" in m.get("content", "") for m in messages)
        has_credit_case = any("Out of credits trigger" in m.get("content", "") for m in messages)
        if is_title and has_credit_case:
            self.send_response(402)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "error": {
                    "message": "insufficient_quota: You exceeded your current quota",
                    "type": "insufficient_quota",
                    "code": "insufficient_quota",
                },
            }).encode())
            return
        if is_title and has_fence_case:
            answer = "``` [main deadbee] git status ```"
        elif is_title and has_colon_case:
            answer = "Neovim 0.13: API migrations"
        else:
            answer = "described."
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        chunk = json.dumps({"choices": [{"delta": {"content": answer}}]})
        self.wfile.write(("data: " + chunk + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", 18139), H).serve_forever()

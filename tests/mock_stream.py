import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        msgs = body["messages"]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        if not has_tool_result:
            chunks = [
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "b1", "type": "function",
                    "function": {"name": "bash", "arguments": json.dumps({"command":
                        "printf 'l1\\nl2\\n'; sleep 0.4; printf 'l3\\n'; printf '<!-- pitel:tool -->\\n'; printf 'tail-without-newline'"})}}]}}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
                {"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 2}},
            ]
        else:
            chunks = [
                {"choices": [{"delta": {"content": "stream done"}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 2}},
            ]
        for c in chunks:
            self.wfile.write(b"data: " + json.dumps(c).encode() + b"\n\n")
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 18141), H).serve_forever()

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if not any(m.get("role") == "tool" for m in body["messages"]):
            # turn 1: request the close_session tool call
            chunks = [
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c1", "type": "function", "function": {"name": "close_session", "arguments": "{}"}}]}}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
            ]
        else:
            tool = [m for m in body["messages"] if m.get("role") == "tool"]
            assert tool[-1]["tool_call_id"] == "c1"
            assert "close requested" in tool[-1]["content"]
            chunks = [{"choices": [{"delta": {"content": "Done. Closing."}}]}]
        chunks.append({"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
        for c in chunks:
            self.wfile.write(b"data: " + json.dumps(c).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 18142), H).serve_forever()

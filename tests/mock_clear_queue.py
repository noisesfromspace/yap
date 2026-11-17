import json
from http.server import BaseHTTPRequestHandler, HTTPServer

# Queued-clear mock: turn 1 calls a slow bash tool (so the frontend can queue
# a :YapClear mid-turn); turn 2 (after the tool result) answers, so the test
# can prove the queued clear ran on the completed turn.
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
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "q1", "type": "function",
                    "function": {"name": "bash", "arguments": json.dumps({"command":
                        "sleep 1.5; echo tool-done"})}}]}}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
                {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3}},
            ]
        else:
            chunks = [
                {"choices": [{"delta": {"content": "all done"}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3}},
            ]
        for c in chunks:
            self.wfile.write(b"data: " + json.dumps(c).encode() + b"\n\n")
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 18171), H).serve_forever()

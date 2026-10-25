import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

# Steering mock: turn 1 calls a slow bash tool (so the frontend can steer
# mid-turn); turn 2 (after the tool result) confirms the steering text reached
# the model and answers.
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
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "s1", "type": "function",
                    "function": {"name": "bash", "arguments": json.dumps({"command":
                        "sleep 1.5; echo tool-done"})}}]}}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
                {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3}},
            ]
        elif "edited instruction" in json.dumps(msgs):
            chunks = [
                {"choices": [{"delta": {"content": "edited answer"}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3}},
            ]
        elif "slow steer answer" in json.dumps(msgs):
            # Answer slowly, so the frontend can stop a turn that has already
            # received a steer: the draft must survive that stop.
            time.sleep(2)
            chunks = [
                {"choices": [{"delta": {"content": "final answer"}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3}},
            ]
        elif "also check the tests" in json.dumps(msgs):
            chunks = [
                {"choices": [{"delta": {"content": "final answer"}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3}},
            ]
        else:
            chunks = [
                {"choices": [{"delta": {"content": "STEER MISSING"}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 3}},
            ]
        try:
            for c in chunks:
                self.wfile.write(b"data: " + json.dumps(c).encode() + b"\n\n")
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass  # the frontend cancelled mid-stream

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 18160), H).serve_forever()

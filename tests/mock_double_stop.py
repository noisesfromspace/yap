import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body["messages"]
        prompt = json.dumps(messages)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if any(m.get("role") == "tool" for m in messages):
            chunks = [{"choices": [{"delta": {"content": "unexpected next model step"}, "finish_reason": "stop"}]}]
        elif "restart" in prompt:
            chunks = [{"choices": [{"delta": {"content": "restarted"}, "finish_reason": "stop"}]}]
        else:
            command = "for i in $(seq 1 10); do echo $i; sleep 1; done; echo too-late" if "hard" in prompt else "for i in $(seq 1 3); do echo $i; sleep 1; done; echo finished"
            chunks = [
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c1", "type": "function",
                    "function": {"name": "bash", "arguments": json.dumps({"command": command})}}]}}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
            ]
        for chunk in chunks:
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", 18166), H).serve_forever()

import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

# Serves both the turn stream (a tool call followed by a delayed final
# answer) and the title summaries (yap send). Title summaries are the
# requests whose system message starts with "Summarize"; their messages
# are logged so the Lua test can assert each stage saw the right input.
LOG = "/tmp/yap-describe-progress.log"


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        msgs = body["messages"]
        is_description = any(
            m.get("role") == "system" and "Summarize" in m.get("content", "")
            for m in msgs
        )

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        if is_description:
            with open(LOG, "a") as f:
                f.write(json.dumps(msgs) + "\n")
            chunks = [{"choices": [{"delta": {"content": "described."}}]}]
        else:
            has_tool_result = any(m.get("role") == "tool" for m in msgs)
            if has_tool_result:
                # Keep the turn alive so the debounced in-turn title
                # refresh fires while the assistant is still working.
                time.sleep(2.0)
                chunks = [
                    {"choices": [{"delta": {"content": "The directory listing is shown above."}}]},
                    {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                    {"choices": [], "usage": {"prompt_tokens": 150, "completion_tokens": 15}},
                ]
            else:
                chunks = [
                    {"choices": [{"delta": {"content": "Let me check. "}}]},
                    {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_1", "type": "function", "function": {"name": "ls", "arguments": "{\"path\":\"/tmp\"}"}}]}}]},
                    {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
                    {"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 20}},
                ]

        for c in chunks:
            self.wfile.write(b"data: " + json.dumps(c).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", 18140), H).serve_forever()

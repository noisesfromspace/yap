import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        msgs = body["messages"]
        assert body.get("tools"), "no tools in request"
        names = [t["function"]["name"] for t in body["tools"]]
        assert names == ["bash", "edit", "fetch", "glob", "ls", "quickfix", "read", "search", "websearch", "write"], names

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        if not has_tool_result:
            # turn 1: request a tool call (streamed in fragments)
            chunks = [
                {"choices": [{"delta": {"content": "Let me check. "}}]},
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_1", "type": "function", "function": {"name": "ls", "arguments": ""}}]}}]},
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "{\"path\":"}}]}}]},
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "\"/tmp\"}"}}]}}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
                {"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 20}},
            ]
        else:
            # turn 2: validate history shape, then answer
            asst = [m for m in msgs if m.get("role") == "assistant" and m.get("tool_calls")]
            assert asst, "no assistant tool_calls message in history"
            call = asst[-1]["tool_calls"][0]
            assert call["id"] == "call_1" and call["function"]["name"] == "ls"
            assert json.loads(call["function"]["arguments"]) == {"path": "/tmp"}
            tool = [m for m in msgs if m.get("role") == "tool"]
            assert tool[-1]["tool_call_id"] == "call_1"
            assert tool[-1]["content"].strip(), "empty ls result"
            assert tool[-1].get("content") and msgs.index(asst[-1]) < msgs.index(tool[-1])
            chunks = [
                {"choices": [{"delta": {"content": "The directory listing is shown above."}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 150, "completion_tokens": 15}},
            ]
        for c in chunks:
            self.wfile.write(b"data: " + json.dumps(c).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 18133), H).serve_forever()

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        msgs = body["messages"]
        assert body.get("tools"), "no tools in request"
        names = [t["function"]["name"] for t in body["tools"]]
        assert names == ["bash", "curl", "edit", "fetch", "git", "glob", "ls", "quickfix", "read", "search", "ssh", "websearch", "write"], names

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        assistant_calls = [m for m in msgs if m.get("role") == "assistant" and m.get("tool_calls")]
        users = [m for m in msgs if m.get("role") == "user"]

        if has_tool_result:
            # In-process tool continuation (single send): the second request
            # must keep native assistant tool_calls + tool results.
            assert assistant_calls, "no assistant tool_calls message in history"
            call = assistant_calls[-1]["tool_calls"][0]
            assert call["id"] == "call_1" and call["function"]["name"] == "ls"
            assert json.loads(call["function"]["arguments"]) == {"path": "/tmp"}
            tool = [m for m in msgs if m.get("role") == "tool"]
            assert tool[-1]["tool_call_id"] == "call_1"
            assert tool[-1]["content"].strip(), "empty ls result"
            assert tool[-1].get("content") and msgs.index(assistant_calls[-1]) < msgs.index(tool[-1])
            chunks = [
                {"choices": [{"delta": {"content": "The directory listing is shown above."}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 150, "completion_tokens": 15}},
            ]
        elif len(users) >= 2:
            # Cross-process follow-up: the persisted tool region was flattened
            # into plain assistant transcript text (no native tool roles/calls).
            assert not assistant_calls, "follow-up transcript still has native tool_calls"
            flat = [m.get("content", "") for m in msgs if m.get("role") == "assistant"]
            assert any("ls" in c for c in flat), "flattened transcript missing tool text: %r" % flat
            chunks = [
                {"choices": [{"delta": {"content": "and in Paris too."}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 150, "completion_tokens": 15}},
            ]
        else:
            # turn 1: request a tool call (streamed in fragments)
            chunks = [
                {"choices": [{"delta": {"content": "Let me check. "}}]},
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_1", "type": "function", "function": {"name": "ls", "arguments": ""}}]}}]},
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "{\"path\":"}}]}}]},
                {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "\"/tmp\"}"}}]}}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
                {"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 20}},
            ]
        for c in chunks:
            self.wfile.write(b"data: " + json.dumps(c).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 18133), H).serve_forever()

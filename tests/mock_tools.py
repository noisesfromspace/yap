#!/usr/bin/env python3
# Mock yap binary for the tools-allowlist tests. As `serve` it echoes the
# request's `tools` allowlist so the Lua test can assert what the frontend
# actually sent.
import json
import sys

payload = json.loads(sys.stdin.readline())
if len(sys.argv) > 1 and sys.argv[1] == "serve":
    tools = payload.get("tools") or []
    print(json.dumps({"type": "text", "text": "received-tools:" + ",".join(sorted(tools))}), flush=True)
    # The real backend always emits turn_complete after its text frames; without
    # it the frontend treats the exit as a failed turn and removes the reply.
    print(json.dumps({"type": "turn_complete", "ok": True}), flush=True)
sys.exit(0)

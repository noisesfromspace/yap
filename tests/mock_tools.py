#!/usr/bin/env python3
# Mock yap binary for the tools-allowlist tests. Answers the `tools`
# subcommand with a fixed list so frontmatter.sync can enumerate it, and
# (as `serve`) echoes the request's `tools` allowlist so the Lua test can
# assert what the frontend actually sent. The `send` subcommand is the
# describe/label path — ignored here.
import json
import sys

TOOLS = ["bash", "ls", "read"]

if len(sys.argv) > 1 and sys.argv[1] == "tools":
    sys.stdout.write("\n".join(TOOLS) + "\n")
    sys.exit(0)

payload = json.loads(sys.stdin.readline())
if len(sys.argv) > 1 and sys.argv[1] == "serve":
    tools = payload.get("tools") or []
    print("received-tools:" + ",".join(sorted(tools)))
sys.exit(0)

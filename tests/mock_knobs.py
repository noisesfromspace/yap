#!/usr/bin/env python3
# Mock yap binary for the temperature/reasoning_level frontmatter test.
# Answers the `tools` subcommand with a fixed list (so frontmatter.sync can
# enumerate tools) and, as `serve`, echoes the `temperature` and
# `reasoning_level` fields the frontend sent, so the Lua test can assert the
# hand-edited frontmatter knobs reach the request payload.
import json
import sys

if len(sys.argv) > 1 and sys.argv[1] == "tools":
    sys.stdout.write("bash\nls\nread\n")
    sys.exit(0)

payload = json.loads(sys.stdin.readline())
if len(sys.argv) > 1 and sys.argv[1] == "serve":
    print("received-temperature:" + str(payload.get("temperature")))
    print("received-reasoning:" + str(payload.get("reasoning_level")))
sys.exit(0)

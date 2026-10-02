#!/usr/bin/env python3
import json
import sys

# The frontend keeps the serve process's stdin open across turns, so read
# exactly one JSON line (json.load would block waiting for EOF). The real
# binary reads line-by-line the same way. Exiting without the turn_end
# sentinel lets the harness close the turn via the error path, which is
# fine here: the cwd text it printed has already been appended.
payload = json.loads(sys.stdin.readline())

msgs = payload["messages"]
if not msgs or msgs[0]["role"] != "system" or not msgs[0]["content"].startswith("# About Yap"):
    sys.exit("missing # About Yap system message at top")

about = msgs[0]["content"]
for instruction in ("## Subagents", "roles_dir", "~/.yap/roles/<role>.md", "self-contained `task`", ":YapSessions", "The call blocks until the child finishes"):
    if instruction not in about:
        sys.exit("missing subagent instruction: " + instruction)

for message in msgs:
    if message["role"] == "system" and message["content"].startswith("Current Neovim working directory: "):
        print(message["content"].removeprefix("Current Neovim working directory: "))
        break
else:
    sys.exit("missing Neovim cwd system message")

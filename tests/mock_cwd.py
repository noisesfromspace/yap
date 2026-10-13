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
for instruction in (
    "## Subagents",
    "agents_dir",
    "~/.config/yap/agents/<agent>.md",
    "self-contained subtask",
    "returns the child's answer and session path",
    "It blocks until the child finishes",
    "isolated context or a different model",
    "The `agent` argument names an agent",
):
    if instruction not in about:
        sys.exit("missing subagent instruction: " + instruction)

# The cwd is request-only context appended to the trailing user message.
for message in msgs:
    if message["role"] == "user":
        for line in message["content"].splitlines():
            if line.startswith("Current Neovim working directory: "):
                print(line.removeprefix("Current Neovim working directory: "))
                sys.exit(0)

sys.exit("missing Neovim cwd user-message context")

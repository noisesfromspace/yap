#!/usr/bin/env python3
import json
import sys

# Same contract as the real binary: read one JSON request line, print a
# framed `text` response record. Echo the injected git snapshot so the test
# can assert on it, or a sentinel when none is present (i.e. :pwd is not a
# git repo). The git snapshot is request-only context appended to the
# trailing user message (not a system message); the title/describe request
# has no "# About Yap" system message and must not echo a snapshot or
# sentinel into the session title.
def emit(text):
    print(json.dumps({"type": "text", "text": text}), flush=True)

payload = json.loads(sys.stdin.readline())
msgs = payload["messages"]

if not msgs or msgs[0]["role"] != "system" or not msgs[0]["content"].startswith("# About Yap"):
    emit("git test")
    sys.exit(0)

for m in msgs:
    if m["role"] == "user":
        idx = m["content"].find("Git: ")
        if idx >= 0:
            emit(m["content"][idx:])
            sys.exit(0)

emit("NO_GIT")

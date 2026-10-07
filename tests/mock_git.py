#!/usr/bin/env python3
import json
import sys

# Same contract as the real binary: read one JSON request line, print a
# response line. Echo the injected git snapshot so the test can assert on it,
# or a sentinel when none is present (i.e. :pwd is not a git repo). The
# title/describe request has no "# About Yap" system message and must not
# echo a snapshot or sentinel into the session description.
payload = json.loads(sys.stdin.readline())
msgs = payload["messages"]

if not msgs or msgs[0]["role"] != "system" or not msgs[0]["content"].startswith("# About Yap"):
    print("git test")
    sys.exit(0)

for m in msgs:
    if m["role"] == "system" and m["content"].startswith("Git: "):
        print(m["content"])
        sys.exit(0)

print("NO_GIT")

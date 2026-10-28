#!/usr/bin/env python3
import json
import sys

# Backend test double with the real binary's `serve` contract: one JSON request
# per line, framed records on stdout, one process for every turn in the
# session. Echo the injected git snapshot so the test can assert on it, or a
# sentinel when none is present (i.e. :pwd is not a git repo). The snapshot is
# request-only context, never part of the transcript or the system prefix; a
# request that is not a session turn (no "# About Yap" prefix, e.g. session
# titling) must not echo either.
def emit(text):
    print(json.dumps({"type": "text", "text": text}), flush=True)


def complete():
    print(json.dumps({"type": "turn_complete", "v": 1, "ok": True}), flush=True)


for line in sys.stdin:
    if not line.strip():
        continue
    payload = json.loads(line)

    if not (payload.get("system") or "").startswith("# About Yap"):
        emit("git test")
        complete()
        continue

    found = False
    for ctx_line in (payload.get("context") or "").splitlines():
        idx = ctx_line.find("Git: ")
        if idx >= 0:
            emit(ctx_line[idx:])
            found = True
            break
    if not found:
        emit("NO_GIT")
    complete()

#!/usr/bin/env python3
import json
import sys

# Backend test double: mirrors the real binary's `serve` contract — one JSON
# request per line on stdin, framed records on stdout, and one process for
# every turn in the session. The frontend ships the raw transcript plus the
# About-Yap system prefix and the transient request-only context (cwd, git);
# the backend owns flattening the transcript into messages.
def emit(text):
    print(json.dumps({"type": "text", "text": text}), flush=True)


def complete():
    print(json.dumps({"type": "turn_complete", "v": 1, "ok": True}), flush=True)


for line in sys.stdin:
    if not line.strip():
        continue
    payload = json.loads(line)

    system = payload.get("system") or ""
    if not system.startswith("# About Yap"):
        sys.exit("missing # About Yap system message")

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
        if instruction not in system:
            sys.exit("missing subagent instruction: " + instruction)

    # The live cwd is request-only context: never written into the transcript,
    # and never part of the system prefix (it would invalidate the prompt
    # cache for the stable history).
    if "Current Neovim working directory:" in (payload.get("transcript") or ""):
        sys.exit("request-only cwd leaked into the transcript")

    found = False
    for ctx_line in (payload.get("context") or "").splitlines():
        if ctx_line.startswith("Current Neovim working directory: "):
            emit(ctx_line.removeprefix("Current Neovim working directory: "))
            found = True
            break
    if not found:
        sys.exit("no cwd in the request context")
    complete()

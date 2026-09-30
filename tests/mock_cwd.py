#!/usr/bin/env python3
import json
import sys

payload = json.load(sys.stdin)
for message in payload["messages"]:
    if message["role"] == "system" and message["content"].startswith("Current Neovim working directory: "):
        print(message["content"].removeprefix("Current Neovim working directory: "))
        break
else:
    sys.exit("missing Neovim cwd system message")

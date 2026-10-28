-- Exercise the Go/Lua event handshake without network or user agent-definition files.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local home = vim.fn.tempname()
vim.fn.mkdir(home .. "/.config/yap/agents", "p")
vim.env.HOME = home
assert(vim.fn.expand("~") == home, "test HOME not isolated")
vim.fn.writefile(
  { "---", "name: scout", "model: pi-only-model", "tools: read, grep", "---", "Scout agent" },
  home .. "/.config/yap/agents/scout.md"
)
vim.fn.writefile(
  { "---", "name: browser", "tools: browser_launch", "---", "Browser agent" },
  home .. "/.config/yap/agents/browser.md"
)
local script = home .. "/backend"
vim.fn.writefile(
  vim.split(
    [=[#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    req = json.loads(line)
    if req.get("type") == "subagent_result":
        continue
    prompt = req.get("transcript") or ""
    # The harness ships the raw transcript; the backend owns flattening it.
    # The task is the body of the last `# @user` block, and request-only
    # context (cwd, git) is appended to it there, so match the task line only.
    body = prompt.rsplit("\n# @user\n", 1)[-1]
    lines = [l for l in body.splitlines() if l.strip()]
    prompt = lines[0] if lines else ""
    first = prompt.splitlines()[0]
    if first.startswith("delegate"):
        agent = "browser" if "unsupported" in first else "scout"
        model = ""
        if "override" in first:
            model = "other/model-b"
        elif "badmodel" in first:
            model = "nonsense"
        print(json.dumps({"type":"subagent_request","id":"1","agent":agent,"model":model,"task":"fail" if "failure" in first else "succeed"}), flush=True)
        response = json.loads(sys.stdin.readline())
        print(json.dumps({"type":"text","text":"\n" + response['result'] + "\n"}), flush=True)
    elif "fail" in first:
        print(json.dumps({"type":"text","text":"\n<!-- yap:error\nchild model failed\n-->\n"}), flush=True)
    else:
        print(json.dumps({"type":"text","text":"\nchild finished\n"}), flush=True)
    print(json.dumps({"type":"turn_complete","ok":True,"v":1}), flush=True)
]=],
    "\n",
    { plain = true }
  ),
  script
)
vim.fn.setfperm(script, "rwx------")
local yap = require("harness")
yap.setup({
  bin = script,
  model_groups = { agent = "mock/working", flash = "" },
  agents_dir = home .. "/.config/yap/agents",
})
local parent = yap.new()
local function delegate(task)
  local lines = vim.api.nvim_buf_get_lines(parent, 0, -1, false)
  vim.api.nvim_buf_set_lines(parent, #lines - 1, #lines, false, { task })
  yap.send(parent)
  assert(
    vim.wait(5000, function()
      return not yap.is_running(parent)
    end, 10),
    "parent did not unblock"
  )
  return table.concat(vim.api.nvim_buf_get_lines(parent, 0, -1, false), "\n")
end
local success = delegate("delegate success")
assert(success:find("child finished", 1, true), success)
local session_line, linked_path = success:match("Session: %[(.-)%]%((.-)%)")
assert(session_line and linked_path == session_line, "child session link missing")
local child_path = linked_path
assert(vim.fn.filereadable(child_path) == 1, "child session missing")
local fm = require("harness.model.frontmatter").parse(vim.fn.readfile(child_path))
assert(fm.provider == "mock" and fm.model == "working", "bare Pi model did not inherit parent combo")
assert(table.concat(fm.tools, ",") == "read,search", "agent aliases not normalized")
assert(fm.subagent_parent == vim.b[parent].yap_path, "child parent path missing")
local parent_fm = require("harness.model.frontmatter").parse(vim.api.nvim_buf_get_lines(parent, 0, -1, false))
assert(
  parent_fm and parent_fm.subagents and #parent_fm.subagents == 1,
  "parent frontmatter did not record the subagent"
)
assert(parent_fm.subagents[1] == child_path, "parent frontmatter subagent path mismatch")
local failure = delegate("delegate failure")
assert(failure:find("error: child model failed", 1, true), failure)
-- A per-call model wins over the agent definition's `model` header; a
-- malformed combo fails the delegation instead of spawning a child.
local overridden = delegate("delegate override")
assert(overridden:find("child finished", 1, true), overridden)
local over_path
for path in overridden:gmatch("Session: %[.-%]%((.-)%)") do
  over_path = path
end
assert(over_path and over_path ~= child_path, "override spawned no new child")
local over_fm = require("harness.model.frontmatter").parse(vim.fn.readfile(over_path))
assert(over_fm.provider == "other" and over_fm.model == "model-b", "per-call model ignored: " .. vim.inspect(over_fm.model))
local bad_model = delegate("delegate badmodel")
assert(bad_model:find("error: invalid subagent model", 1, true), bad_model)
local unsupported = delegate("delegate unsupported")
assert(unsupported:find("error: agent definition browser requires unsupported tool browser_launch", 1, true), unsupported)
print("OK subagent integration")

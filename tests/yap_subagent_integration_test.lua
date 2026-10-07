-- Exercise the Go/Lua event handshake without network or user agent-definition files.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local home = vim.fn.tempname()
vim.fn.mkdir(home .. "/.yap/agents", "p")
vim.env.HOME = home
assert(vim.fn.expand("~") == home, "test HOME not isolated")
vim.fn.writefile(
  { "---", "name: scout", "model: pi-only-model", "tools: read, grep", "---", "Scout agent" },
  home .. "/.yap/agents/scout.md"
)
vim.fn.writefile(
  { "---", "name: browser", "tools: browser_launch", "---", "Browser agent" },
  home .. "/.yap/agents/browser.md"
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
    prompt = req["messages"][-1]["content"]
    if prompt.startswith("delegate"):
        agent = "browser" if "unsupported" in prompt else "scout"
        session = prompt.split("session=", 1)[1].split()[0] if "session=" in prompt else ""
        print('yap:event ' + json.dumps({"type":"subagent_request","id":"1","agent":"" if session else agent,"session":session,"task":"follow up" if session else ("fail" if "failure" in prompt else "succeed")}), file=sys.stderr, flush=True)
        response = json.loads(sys.stdin.readline())
        print('\n' + response['result'] + '\n', flush=True)
    elif "follow up" in prompt:
        assert "Scout agent" in str(req["messages"]), "system prompt lost on follow-up"
        assert "succeed" in str(req["messages"]), "first question lost on follow-up"
        print('\nfollow-up answered\n', flush=True)
    elif "fail" in prompt:
        print('\n<!-- yap:error\nchild model failed\n-->\n', flush=True)
    else:
        print('\nchild finished\n', flush=True)
    print('\x1eyap:turn_end {"ok":true}', flush=True)
    print('yap:event {"type":"turn_complete"}', file=sys.stderr, flush=True)
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
  provider = "mock",
  model = "working",
  description_model = "",
  description_answer_model = "",
  agents_dir = home .. "/.yap/agents",
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
local fm = require("harness.frontmatter").parse(vim.fn.readfile(child_path))
assert(fm.provider == "mock" and fm.model == "working", "bare Pi model did not inherit parent combo")
assert(table.concat(fm.tools, ",") == "read,search", "agent aliases not normalized")
assert(fm.subagent_parent == vim.b[parent].yap_path, "child parent path missing")
local parent_fm = require("harness.frontmatter").parse(vim.api.nvim_buf_get_lines(parent, 0, -1, false))
assert(
  parent_fm and parent_fm.subagents and #parent_fm.subagents == 1,
  "parent frontmatter did not record the subagent"
)
assert(parent_fm.subagents[1] == child_path, "parent frontmatter subagent path mismatch")
local followup = delegate("delegate session=" .. child_path)
assert(followup:find("follow-up answered", 1, true), followup)
local child_text = table.concat(vim.fn.readfile(child_path), "\n")
assert(child_text:find("# @user\n\nfollow up", 1, true), "follow-up not appended as user message")
assert(child_text:find("# @system\n\nScout agent", 1, true), "child system prompt changed")
local after = require("harness.frontmatter").parse(vim.api.nvim_buf_get_lines(parent, 0, -1, false))
assert(#after.subagents == 1, "follow-up created another child session")
local unknown = delegate("delegate session=" .. home .. "/other.md")
assert(unknown:find("error: subagent session not found", 1, true), unknown)
local failure = delegate("delegate failure")
assert(failure:find("error: child model failed", 1, true), failure)
local unsupported = delegate("delegate unsupported")
assert(unsupported:find("error: agent definition browser requires unsupported tool browser_launch", 1, true), unsupported)
print("OK subagent integration")

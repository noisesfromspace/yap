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
    prompt = req["messages"][-1]["content"]
    # The harness appends the Neovim cwd and git context to the user message,
    # so substring-matching the whole prompt is fragile: a recent commit like
    # "describe: notify on title/summary model failure" puts the word "failure"
    # into a "delegate success" prompt and misclassifies it. Match on the task
    # line only — the text before the injected context.
    first = prompt.splitlines()[0]
    if first.startswith("delegate"):
        agent = "browser" if "unsupported" in first else "scout"
        session = first.split("session=", 1)[1].split()[0] if "session=" in first else ""
        model = ""
        if "override" in first:
            model = "other/model-b"
        elif "badmodel" in first:
            model = "nonsense"
        elif "followupmodel" in first:
            model = "other/model-c"
        print('yap:event ' + json.dumps({"type":"subagent_request","id":"1","agent":"" if session else agent,"model":model,"session":session,"task":"follow up" if session else ("fail" if "failure" in first else "succeed")}), file=sys.stderr, flush=True)
        response = json.loads(sys.stdin.readline())
        print('\n' + response['result'] + '\n', flush=True)
    elif "follow up" in first:
        assert "Scout agent" in str(req["messages"]), "system prompt lost on follow-up"
        assert "succeed" in str(req["messages"]), "first question lost on follow-up"
        print('\nfollow-up answered\n', flush=True)
    elif "fail" in first:
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
  model_groups = { title = "" },
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
-- A per-call model wins over the agent definition's `model` header; a
-- malformed combo fails the delegation instead of spawning a child.
local overridden = delegate("delegate override")
assert(overridden:find("child finished", 1, true), overridden)
local over_path
for path in overridden:gmatch("Session: %[.-%]%((.-)%)") do
  over_path = path
end
assert(over_path and over_path ~= child_path, "override spawned no new child")
local over_fm = require("harness.frontmatter").parse(vim.fn.readfile(over_path))
assert(over_fm.provider == "other" and over_fm.model == "model-b", "per-call model ignored: " .. vim.inspect(over_fm.model))
-- A follow-up ignores `model`: the child keeps the combo in its frontmatter.
local followup_model = delegate("delegate session=" .. over_path .. " followupmodel")
assert(followup_model:find("follow-up answered", 1, true), followup_model)
local over_after = require("harness.frontmatter").parse(vim.fn.readfile(over_path))
assert(
  over_after.provider == "other" and over_after.model == "model-b",
  "follow-up changed the child's combo: " .. vim.inspect(over_after.provider .. "/" .. over_after.model)
)
local bad_model = delegate("delegate badmodel")
assert(bad_model:find("error: invalid subagent model", 1, true), bad_model)
local unsupported = delegate("delegate unsupported")
assert(unsupported:find("error: agent definition browser requires unsupported tool browser_launch", 1, true), unsupported)
print("OK subagent integration")

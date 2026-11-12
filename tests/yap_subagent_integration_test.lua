-- Exercise the Go/Lua event handshake without network or user agent-definition files.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local home = vim.fn.tempname()
vim.fn.mkdir(home .. "/.config/yap/agents", "p")
vim.env.HOME = home
assert(vim.fn.expand("~") == home, "test HOME not isolated")
vim.fn.writefile(
  { "---", "name: scout", "model: pi-only-model", "---", "Scout agent" },
  home .. "/.config/yap/agents/scout.md"
)
vim.fn.writefile({ "---", "name: browser", "---", "Browser agent" }, home .. "/.config/yap/agents/browser.md")
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
    # transient context is appended there, so match the task line only.
    body = prompt.rsplit("\n# @user\n", 1)[-1]
    lines = [l for l in body.splitlines() if l.strip()]
    prompt = lines[0] if lines else ""
    first = prompt.splitlines()[0]
    if first.startswith("delegate"):
        agent = "browser" if "unsupported" in first else "scout"
        tools = ["read", "search"]
        if "newtool" in first:
            tools = ["read", "mcp_example_query"]
        elif "unsupported" in first:
            tools = ["subagent"]
        elif "missingtools" in first:
            tools = None
        model = ""
        if "override" in first:
            model = "other/model-b"
        elif "badmodel" in first:
            model = "nonsense"
        print(json.dumps({"type":"subagent_request","id":"1","agent":agent,"model":model,"task":"fail" if "failure" in first else "markers" if "markers" in first else "succeed", "tools":tools}), flush=True)
        # The harness first confirms the child path, then relays progress
        # signals as the child works, then sends the result when it finishes.
        response = {}
        saw_progress = False
        while "result" not in response:
            response = json.loads(sys.stdin.readline())
            if response.get("type") == "subagent_progress":
                saw_progress = True
        print(json.dumps({"type":"text","text":"\n" + response['result'] + "\nPROGRESS=" + ("1" if saw_progress else "0") + "\n"}), flush=True)
    elif "markers" in first:
        print(json.dumps({"type":"text","text":"\n<!-- yap:thinking\nsecret thought\n-->\n<!-- yap:tool {\\\"id\\\":\\\"t\\\",\\\"name\\\":\\\"read\\\"} -->\n```\n# @assistant\nquoted heading\n```\n<!-- /yap:tool -->\nchild visible answer\n"}), flush=True)
    elif "fail" in first:
        print(json.dumps({"type":"text","text":"\n<!-- yap:error\nchild model failed\n-->\n"}), flush=True)
    else:
        # A child that runs a tool: the harness relays its activity to the
        # parent as a subagent_progress liveness signal.
        print(json.dumps({"type":"event","event":{"type":"tool_start","name":"read","log":"/tmp/child.log","command":"read"}}), flush=True)
        print(json.dumps({"type":"tool_output","log":"/tmp/child.log","delta":"line one\nline two\n"}), flush=True)
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
assert(success:find("PROGRESS=1", 1, true), "parent did not receive subagent progress: " .. success)
local session_line, linked_path = success:match("Session: %[(.-)%]%((.-)%)")
assert(session_line and linked_path == session_line, "child session link missing")
local child_path = linked_path
assert(vim.fn.filereadable(child_path) == 1, "child session missing")
local fm = require("harness.model.frontmatter").parse(vim.fn.readfile(child_path))
assert(fm.provider == "mock" and fm.model == "working", "bare Pi model did not inherit parent combo")
assert(table.concat(fm.tools, ",") == "read,search", "caller-selected tools missing")
assert(fm.subagent_parent == vim.fn.fnamemodify(vim.b[parent].yap_path, ":h"), "child parent directory missing")
local child_buf = vim.fn.bufnr(child_path)
assert(child_buf > 0, "child buffer missing")
require("harness.model.frontmatter").update(child_buf, { tools = {} })
assert(yap.send(child_buf) == false, "a child with an empty tools list became unrestricted")
-- The link is the child's own `subagent_parent` (a directory), not a list on
-- the parent, so a `:file` rename of either transcript never breaks it.
local parent_fm = require("harness.model.frontmatter").parse(vim.api.nvim_buf_get_lines(parent, 0, -1, false))
assert(not parent_fm.subagents, "parent frontmatter should not list subagents")
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
assert(
  over_fm.provider == "other" and over_fm.model == "model-b",
  "per-call model ignored: " .. vim.inspect(over_fm.model)
)
local bad_model = delegate("delegate badmodel")
assert(bad_model:find("error: invalid subagent model", 1, true), bad_model)
local unsupported = delegate("delegate unsupported")
assert(unsupported:find("error: invalid subagent tool subagent", 1, true), unsupported)
local missing = delegate("delegate missingtools")
assert(missing:find("error: subagent requires a nonempty tools list", 1, true), missing)
local marked = delegate("delegate markers")
assert(marked:find("child visible answer", 1, true), marked)
assert(not marked:find("quoted heading", 1, true) and not marked:find("secret thought", 1, true), marked)
local dynamic = delegate("delegate newtool")
local dynamic_path
for path in dynamic:gmatch("Session: %[.-%]%((.-)%)") do
  dynamic_path = path
end
assert(dynamic_path, "dynamic tools child missing")
local dynamic_fm = require("harness.model.frontmatter").parse(vim.fn.readfile(dynamic_path))
assert(table.concat(dynamic_fm.tools, ",") == "read,mcp_example_query", "dynamic tools not forwarded")
print("OK subagent integration")

-- Exercise the Go/Lua event handshake without network or user role files.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local home = vim.fn.tempname()
vim.fn.mkdir(home .. "/.yap/roles", "p")
vim.env.HOME = home
assert(vim.fn.expand("~") == home, "test HOME not isolated")
vim.fn.writefile({ "---", "name: scout", "model: pi-only-model", "tools: read, grep", "---", "Scout role" }, home .. "/.yap/roles/scout.md")
vim.fn.writefile({ "---", "name: browser", "tools: browser_launch", "---", "Browser role" }, home .. "/.yap/roles/browser.md")
local script = home .. "/backend"
vim.fn.writefile(vim.split([=[#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    req = json.loads(line)
    if req.get("type") == "subagent_result":
        continue
    prompt = req["messages"][-1]["content"]
    if prompt.startswith("delegate"):
        role = "browser" if "unsupported" in prompt else "scout"
        print('yap:event ' + json.dumps({"type":"subagent_request","id":"1","role":role,"task":"fail" if "failure" in prompt else "succeed"}), file=sys.stderr, flush=True)
        response = json.loads(sys.stdin.readline())
        print('\n' + response['result'] + '\n', flush=True)
    elif "fail" in prompt:
        print('\n<!-- yap:error\nchild model failed\n-->\n', flush=True)
    else:
        print('\nchild finished\n', flush=True)
    print('\x1eyap:turn_end {"ok":true}', flush=True)
    print('yap:event {"type":"turn_complete"}', file=sys.stderr, flush=True)
]=], "\n", { plain = true }), script)
vim.fn.setfperm(script, "rwx------")
local yap = require("harness")
yap.setup({ bin = script, provider = "mock", model = "working", description_model = "", description_answer_model = "", roles_dir = home .. "/.yap/roles" })
local parent = yap.new()
local function delegate(task)
  local lines = vim.api.nvim_buf_get_lines(parent, 0, -1, false)
  vim.api.nvim_buf_set_lines(parent, #lines - 1, #lines, false, { task })
  yap.send(parent)
  assert(vim.wait(5000, function() return not yap.is_running(parent) end, 10), "parent did not unblock")
  return table.concat(vim.api.nvim_buf_get_lines(parent, 0, -1, false), "\n")
end
local success = delegate("delegate success")
assert(success:find("child finished", 1, true), success)
local child_path = success:match("Session: ([^\n]+%.md)")
assert(child_path and vim.fn.filereadable(child_path) == 1, "child session missing")
local fm = require("harness.frontmatter").parse(vim.fn.readfile(child_path))
assert(fm.provider == "mock" and fm.model == "working", "bare Pi model did not inherit parent combo")
assert(table.concat(fm.tools, ",") == "read,search", "role aliases not normalized")
local failure = delegate("delegate failure")
assert(failure:find("error: child model failed", 1, true), failure)
local unsupported = delegate("delegate unsupported")
assert(unsupported:find("error: role browser requires unsupported tool browser_launch", 1, true), unsupported)
print("OK subagent integration")

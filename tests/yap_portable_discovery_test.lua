-- The saved-session picker (sessions(), '+') discovers portable transcripts:
-- project sessions under <root>/.yap-sessions (cwd + git root) are listed
-- even after the buffer is closed, and an open next-to-file/custom transcript
-- is listed while its buffer pins it. Closing such an arbitrary-location
-- transcript removes it (there is no index to find it again).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

local session = require("harness.session")
local paths = require("harness.path")
local frontmatter = require("harness.model.frontmatter")

local project = vim.fn.tempname()
vim.fn.mkdir(project, "p")
vim.cmd("cd " .. vim.fn.fnameescape(project))

local function listed(scope)
  local out = {}
  for _, item in ipairs(session.list(scope)) do
    out[vim.fs.normalize(item.path)] = item
  end
  return out
end

-- 1. A project session under .yap-sessions/ is found from disk (its
--    transcript path, not the open buffer) once it has an identity.
local proj = yap.new({ path = paths.new_session_path(project .. "/.yap-sessions"), provider = "mock", model = "m1" })
local proj_path = vim.fs.normalize(vim.b[proj].yap_path)
frontmatter.update(proj, { description = "Project plan" })
session.save(proj)
vim.cmd("bwipeout!")
local by_path = listed("cwd")
assert(by_path[proj_path], "project session missing from + list: " .. vim.inspect(by_path))

-- 2. A next-to-file transcript is listed only while its buffer is open.
local nt = yap.new({ path = project .. "/topic.md", provider = "mock", model = "m1" })
local nt_path = vim.fs.normalize(vim.b[nt].yap_path)
frontmatter.update(nt, { description = "Topic thread" })
session.save(nt)
by_path = listed("cwd")
assert(by_path[nt_path], "open portable transcript missing from + list")

-- 3. The + picker itself surfaces the open portable transcript.
local captured
local select = vim.ui.select
vim.ui.select = function(items, opts)
  captured = { items = items, format = opts.format_item }
end
yap.sessions()
vim.ui.select = select
local seen = false
for _, item in ipairs(captured.items) do
  if vim.fs.normalize(item.path) == nt_path then
    seen = true
    break
  end
end
assert(seen, "open portable transcript missing from the + picker items")

-- 4. Closing an arbitrary-location transcript removes it; the project
--    convention one stays (it is discoverable from disk).
vim.api.nvim_buf_delete(nt, { force = true })
by_path = listed("cwd")
assert(by_path[proj_path], "project session should survive close")
assert(not by_path[nt_path], "closed next-to-file transcript should no longer be listed")

print("OK portable discovery")

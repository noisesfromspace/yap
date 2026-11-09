-- The saved-session picker (sessions(), '+') lists an open portable
-- transcript while its buffer pins it: a session created next to a file or at
-- a custom path has no fixed discoverable location, so closing the buffer
-- removes it (there is no index to find it again).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

local session = require("harness.session")
local frontmatter = require("harness.model.frontmatter")

local project = vim.fn.tempname()
vim.fn.mkdir(project, "p")
vim.cmd("cd " .. vim.fn.fnameescape(project))

local function listed()
  local out = {}
  for _, item in ipairs(session.list()) do
    out[vim.fs.normalize(item.path)] = item
  end
  return out
end

-- 1. A next-to-file transcript is listed while its buffer is open.
local nt = yap.new({ path = project .. "/topic.md", provider = "mock", model = "m1" })
local nt_path = vim.fs.normalize(vim.b[nt].yap_path)
frontmatter.update(nt, { description = "Topic thread" })
session.save(nt)
local by_path = listed()
assert(by_path[nt_path], "open portable transcript missing from + list")

-- 2. The + picker itself surfaces the open portable transcript.
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

-- 3. Closing the transcript removes it from the list.
vim.api.nvim_buf_delete(nt, { force = true })
by_path = listed()
assert(not by_path[nt_path], "closed next-to-file transcript should no longer be listed")

-- 4. A session saved under another project's slug folder is not listed from
-- this project until its transcript is opened; once open, its buffer pins it
-- in sessions() so it stays reachable while it is loaded.
local here = vim.fn.getcwd()
local other = vim.fn.tempname()
vim.fn.mkdir(other, "p")
vim.cmd("cd " .. vim.fn.fnameescape(other))
local foreign = yap.new({ provider = "mock", model = "m1" })
local foreign_path = vim.b[foreign].yap_path
frontmatter.update(foreign, { description = "Foreign project" })
session.save(foreign)
vim.api.nvim_buf_delete(foreign, { force = true })
vim.cmd("cd " .. vim.fn.fnameescape(here))
assert(not listed()[vim.fs.normalize(foreign_path)], "closed foreign session should not be listed")
yap.open(foreign_path)
assert(vim.b[vim.api.nvim_get_current_buf()].yap == true, "foreign session not adopted on open")
assert(listed()[vim.fs.normalize(foreign_path)], "open foreign session missing from the list")

print("OK portable discovery")

-- <leader>y opens a new-session location chooser: global (default :Yap),
-- project (.yap-sessions/ under the cwd), next to the current file, and a
-- custom path. A non-global choice creates a portable transcript (frontmatter
-- data_dir); global keeps the rooted default.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})

local paths = require("harness.path")
local frontmatter = require("harness.model.frontmatter")

-- The chooser keymap is global and installed by setup().
assert(vim.fn.maparg("<leader>y", "n") ~= "", "no global <leader>y new-session map")

-- Capture the chooser items without acting on a choice.
local function capture()
  local items
  local select = vim.ui.select
  vim.ui.select = function(it, opts, cb)
    assert(opts.prompt == "New yap session", "unexpected prompt: " .. tostring(opts.prompt))
    items = it
  end
  yap.new_session()
  vim.ui.select = select
  return items
end

-- Capture and immediately choose one destination.
local function choose(index)
  local select = vim.ui.select
  vim.ui.select = function(it, opts, cb)
    vim.ui.select = select
    cb(it[index])
  end
  yap.new_session()
  vim.ui.select = select
end

-- A real non-session file supplies the "next to current file" destination.
local tdir = vim.fn.tempname()
vim.fn.mkdir(tdir, "p")
local here = tdir .. "/note.lua"
vim.fn.writefile({ "print('x')" }, here)
vim.cmd("edit " .. vim.fn.fnameescape(here))

-- 1. The four destinations, in order.
local items = capture()
assert(#items == 4, "expected four destinations, got " .. #items)
assert(items[1].text == "Global session", "first destination is not global")
assert(items[2].text == "Project session", "second destination is not project")
assert(items[3].text == "Next to current file", "third destination is not next-to-file")
assert(items[4].text == "Custom path…", "fourth destination is not custom")
assert(items[2].detail:find("/.yap-sessions/", 1, true), "project detail missing its folder")
assert(items[3].detail == tdir .. "/note.md", "next-to-file detail wrong: " .. items[3].detail)

-- 2. Project: a portable transcript under <cwd>/.yap-sessions/.
choose(2)
local proj = vim.api.nvim_get_current_buf()
assert(vim.b[proj].yap == true, "project choice did not open a session")
assert(vim.b[proj].yap_path:find("/.yap-sessions/", 1, true), "project session not under .yap-sessions: " .. tostring(vim.b[proj].yap_path))
local proj_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(proj, 0, 30, false))
assert(proj_fm and proj_fm.data_dir, "project session missing data_dir")

-- 3. Next to current file: <dir>/<stem>.md beside the file being edited.
vim.cmd("edit " .. vim.fn.fnameescape(here))
choose(3)
local nextbuf = vim.api.nvim_get_current_buf()
assert(vim.b[nextbuf].yap == true, "next-to-file choice did not open a session")
assert(vim.b[nextbuf].yap_path == tdir .. "/note.md", "next-to-file path wrong: " .. tostring(vim.b[nextbuf].yap_path))
local next_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(nextbuf, 0, 30, false))
assert(next_fm and next_fm.data_dir, "next-to-file session missing data_dir")

-- 4. Global: the rooted default, no data_dir.
vim.cmd("enew")
choose(1)
local glob = vim.api.nvim_get_current_buf()
assert(vim.b[glob].yap == true, "global choice did not open a session")
assert(paths.under_sessions_root(vim.b[glob].yap_path), "global session left the sessions root")
local glob_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(glob, 0, 30, false))
assert(glob_fm.data_dir == nil, "global session should have no data_dir")

print("OK new session launcher")

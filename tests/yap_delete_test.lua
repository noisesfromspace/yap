local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local paths = require("harness.path")
local state = require("harness.state")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
yap.setup({ sessions_dir = tmp .. "/sessions", model_groups = { agent = "mock/m1", flash = "" } })
vim.cmd("runtime plugin/yap.lua")

local function exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

local buf = yap.new()
vim.cmd("file renamed.md")
local transcript = vim.b[buf].yap_path
local dir = paths.data_dir(buf)
local notes_path = paths.notes_path(buf)
local audit = paths.audit_path(buf)
vim.fn.writefile({ "{}" }, audit)
local assets = paths.assets_dir(buf)
vim.fn.mkdir(assets .. "/nested", "p")
vim.fn.writefile({ "asset" }, assets .. "/nested/file")
local keep = tmp .. "/unrelated"
vim.fn.mkdir(keep, "p")
vim.fn.writefile({ "keep" }, keep .. "/file")
assert(vim.uv.fs_symlink(keep, assets .. "/link"))

local win = vim.api.nvim_get_current_win()
yap.scratch_toggle()
local notes = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(notes) == notes_path)
vim.api.nvim_buf_set_lines(notes, -1, -1, false, { "unsaved scratch" })
vim.api.nvim_set_current_win(win)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "unsaved prompt" })

local bang_ok, bang_err = pcall(vim.cmd, "YapDelete!")
assert(not bang_ok and bang_err:find("E477", 1, true) and exists(transcript), "bang should be rejected")
state.running[buf] = {}
local ok, err = yap.delete()
assert(not ok and err:find("running turn", 1, true) and exists(transcript))
state.running[buf] = nil
local confirm = vim.fn.confirm
vim.fn.confirm = function()
  error("YapDelete must not ask for confirmation")
end
vim.cmd("YapDelete")
vim.fn.confirm = confirm
assert(not vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_buf_is_valid(notes), "session buffers survived")
assert(not exists(transcript) and not exists(notes_path) and not exists(audit) and not exists(assets))
assert(not exists(dir), "empty data directory survived")
assert(exists(keep .. "/file"), "deletion followed an asset symlink")

local portable = tmp .. "/portable.md"
buf = yap.new({ path = portable })
dir = paths.data_dir(buf)
vim.cmd("YapDelete")
assert(not exists(portable) and not exists(dir) and exists(keep), "portable cleanup escaped its data directory")

-- Two transcripts in a directory can share sidecars. Leave them intact.
buf = yap.new()
dir = paths.data_dir(buf)
local sibling = dir .. "/another.md"
transcript = paths.session_path(buf)
vim.fn.writefile({ "another transcript" }, sibling)
vim.cmd("YapDelete")
assert(not exists(transcript) and exists(sibling) and exists(dir .. "/notes.md"))

-- An adopted transcript can name an arbitrary directory in frontmatter.
local external = tmp .. "/external.md"
vim.fn.writefile({ "---", "provider: mock", "model: m1", "data_dir: " .. keep, "---" }, external)
yap.open(external)
vim.fn.writefile({ "untouched" }, keep .. "/audit.jsonl")
vim.cmd("YapDelete")
assert(not exists(external) and exists(keep .. "/notes.md") and exists(keep .. "/audit.jsonl"))

local ordinary = vim.api.nvim_get_current_buf()
assert(not vim.b[ordinary].yap)
assert(not yap.delete() and vim.api.nvim_buf_is_valid(ordinary), "deleted a non-session buffer")
assert(vim.fn.delete(tmp, "rf") == 0)
print("OK yap delete")

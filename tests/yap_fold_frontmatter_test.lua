local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime! plugin/yap.lua")
local yap = require("harness")
local fold = require("harness.ui.fold")
local structure = require("harness.model.structure")

local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "---",
  "model: m1",
  "provider: p1",
  "---",
  "",
  "# @system",
  "",
  "You are helpful.",
  "",
  "# @user",
  "",
  "Question one.",
  "",
  "# @assistant",
  "",
  "Answer one.",
  "",
})
fold.setup_buffer(buf)

-- The parser emits the frontmatter as its own unit (lines 1..4 inclusive).
local p = structure.parse(buf)
assert(p.frontmatter == 4, "frontmatter range: " .. tostring(p.frontmatter))

-- default view 2: frontmatter and system folded, conversation open.
assert(vim.fn.foldclosed(1) == 1, "frontmatter should be folded by default")
assert(vim.fn.foldclosed(6) == 6, "system should be folded by default")
assert(vim.fn.foldclosed(10) == -1, "user 1 should be open")
assert(vim.fn.foldclosed(14) == -1, "assistant should be open by default")
assert(fold.text(1, 4) == "▸ options", "foldtext: " .. fold.text(1, 4))

-- view 1 folds assistant messages too; frontmatter/system stay folded.
fold.set_view_level(1)
assert(vim.fn.foldclosed(1) == 1, "view 1 folds the frontmatter")
assert(vim.fn.foldclosed(6) == 6, "view 1 folds the system")
assert(vim.fn.foldclosed(10) == -1, "view 1 keeps user open")
assert(vim.fn.foldclosed(14) == 14, "view 1 folds assistant")

-- view 3 unfolds everything, including the frontmatter.
fold.set_view_level(3)
assert(vim.fn.foldclosed(1) == -1, "view 3 unfolds the frontmatter")
assert(vim.fn.foldclosed(6) == -1, "view 3 unfolds the system")

-- A save re-stamps `updated_at` and `turns`. It must rewrite only the lines
-- that differ: replacing the whole block deletes the window's manual fold
-- over it, so every save closed the options fold the user had opened.
fold.set_view_level(2)
fold.open(1)
assert(vim.fn.foldclosed(1) == -1, "frontmatter open after fold.open")
require("harness.session").save(buf)
vim.wait(300)
local stamped = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(stamped[4] == "turns: 1", "turns not stamped: " .. tostring(stamped[4]))
assert(vim.fn.foldclosed(1) == -1, "a save must not close the options fold")
assert(vim.fn.foldclosed(8) == 8, "a save must not open the system fold")

print("OK fold_frontmatter")

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime! plugin/yap.lua")
local yap = require("harness")
local fold = require("harness.fold")
local structure = require("harness.structure")

local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "---",
  "title:",
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

-- The parser emits the frontmatter as its own unit (lines 1..5 inclusive).
local p = structure.parse(buf)
assert(p.frontmatter == 5, "frontmatter range: " .. tostring(p.frontmatter))

-- default view 2: frontmatter and system folded, conversation open.
assert(vim.fn.foldclosed(1) == 1, "frontmatter should be folded by default")
assert(vim.fn.foldclosed(7) == 7, "system should be folded by default")
assert(vim.fn.foldclosed(11) == -1, "user 1 should be open")
assert(vim.fn.foldclosed(15) == -1, "assistant should be open by default")
assert(fold.text(1, 5) == "▸ options (5 lines)", "foldtext: " .. fold.text(1, 5))

-- view 1 folds assistant messages too; frontmatter/system stay folded.
fold.set_view_level(1)
assert(vim.fn.foldclosed(1) == 1, "view 1 folds the frontmatter")
assert(vim.fn.foldclosed(7) == 7, "view 1 folds the system")
assert(vim.fn.foldclosed(11) == -1, "view 1 keeps user open")
assert(vim.fn.foldclosed(15) == 15, "view 1 folds assistant")

-- view 3 unfolds everything, including the frontmatter.
fold.set_view_level(3)
assert(vim.fn.foldclosed(1) == -1, "view 3 unfolds the frontmatter")
assert(vim.fn.foldclosed(7) == -1, "view 3 unfolds the system")

print("OK fold_frontmatter")

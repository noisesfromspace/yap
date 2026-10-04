local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.fold")
local document = require("harness.document")

local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system", "", "sys", "",
  "# @user", "", "Q1", "",
  "# @assistant", "",
  '<!-- yap:tool {"id":"t1","name":"bash","arguments":{}} -->',
  "result t1",
  "<!-- /yap:tool -->",
  "A1 answer", "",
  "# @user", "", "Q2", "",
  "# @assistant", "",
  '<!-- yap:tool {"id":"t2","name":"bash","arguments":{}} -->',
  "result t2",
  "<!-- /yap:tool -->",
  "A2 answer", "",
})

local function headings(role)
  local t = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l == "# @" .. role then t[#t + 1] = i end
  end
  return t
end
local function tool_line(id)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match('"' .. id .. '"') then return i end
  end
end

fold.set_view_level(1)
local a = headings("assistant")
assert(vim.fn.foldclosed(a[1]) == a[1], "view 1 should fold older assistant")
assert(vim.fn.foldclosed(a[2]) == a[2], "view 1 should fold last assistant")

-- ── no leak: user opens a tool, a NEW tool still arrives folded ─────────
fold.set_view_level(2)
local t1 = tool_line("t1")
vim.api.nvim_win_set_cursor(0, { t1, 0 })
vim.cmd("normal! za")
assert(vim.fn.foldclosed(t1) == -1, "za did not open t1")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
  '<!-- yap:tool {"id":"t3","name":"bash","arguments":{}} -->', "result t3", "<!-- /yap:tool -->",
})
fold.after_append(buf, { '<!-- yap:tool {"id":"t3","name":"bash","arguments":{}} -->' })
local t3 = tool_line("t3")
assert(vim.fn.foldclosed(t1) == -1, "streaming t3 closed the user-opened t1")
assert(vim.fn.foldclosed(t3) == t3, "t3 leaked open while t1 was open")

-- ── cursor and topline stay pinned through a structural append ──────────
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.cmd("normal! zt")
local v0 = vim.fn.winsaveview()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "# @assistant", "A3", "" })
fold.after_append(buf, { "# @assistant" })
local v1 = vim.fn.winsaveview()
assert(v0.lnum == v1.lnum and v0.col == v1.col, "cursor moved during reconcile")
assert(v0.topline == v1.topline, "topline moved during reconcile")

-- ── new replies stay folded, user-opened old one stays open ─────────────
fold.set_view_level(1)
local a2 = headings("assistant")
assert(vim.fn.foldclosed(a2[1]) == a2[1], "older assistant should fold in view 1")
assert(vim.fn.foldclosed(a2[3]) == a2[3], "newest assistant should stay folded in view 1")
-- za-open the older assistant, then a new reply must not fold it
vim.api.nvim_win_set_cursor(0, { a2[1], 0 })
vim.cmd("normal! za")
assert(vim.fn.foldclosed(a2[1]) == -1, "za did not open older assistant")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "# @user", "", "Q3", "", "# @assistant", "A4", "" })
fold.after_append(buf, { "# @assistant" })
local a3 = headings("assistant")
assert(vim.fn.foldclosed(a2[1]) == -1, "user-opened old assistant folded on new reply")
assert(vim.fn.foldclosed(a2[2]) == a2[2], "other assistant opened")
assert(vim.fn.foldclosed(a3[4]) == a3[4], "newest assistant opened in view 1")

print("OK fold_reconcile")

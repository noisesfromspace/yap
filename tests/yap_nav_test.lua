local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.fold")

local buf = yap.new()
vim.wo.foldlevel = 99 -- navigation must not be hidden by closed folds
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system", "", "You are helpful.", "",
  "# @user", "", "Q1.", "",
  "# @assistant", "",
  "<!-- yap:thinking", "hmm", "-->",
  "", "Answer with a tool.", "",
  "<!-- yap:tool", '{ "id":"c1","name":"bash","arguments":{} }', "-->",
  "```", "output", "```",
  "<!-- /yap:tool -->",
  "", "Done.", "",
  "# @user", "", "Q2.", "",
  "# @assistant", "",
  "<!-- yap:thinking", "more", "-->",
  "", "<!-- yap:error", "boom", "-->",
  "", "Failed.", "",
  "# @user", "",
})
fold.setup_buffer(buf)

-- openers (1-based)
local think1, tool1, think2, error1 = 11, 17, 33, 37

local function cursor()
  return vim.api.nvim_win_get_cursor(0)[1]
end

-- thinking
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.next_think()
assert(cursor() == think1, "next_think -> " .. think1 .. ", got " .. cursor())
fold.next_think()
assert(cursor() == think2, "next_think -> " .. think2 .. ", got " .. cursor())
fold.prev_think()
assert(cursor() == think1, "prev_think -> " .. think1 .. ", got " .. cursor())
fold.prev_think()
assert(cursor() == think1, "prev_think wraps past first stays put, got " .. cursor())

-- tool
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.next_tool()
assert(cursor() == tool1, "next_tool -> " .. tool1 .. ", got " .. cursor())
fold.prev_tool()
assert(cursor() == tool1, "prev_tool past only tool stays put, got " .. cursor())

-- error
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.next_error()
assert(cursor() == error1, "next_error -> " .. error1 .. ", got " .. cursor())
fold.prev_error()
assert(cursor() == error1, "prev_error past only error stays put, got " .. cursor())

-- navigation is also mapped in normal mode
local seen = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
  seen[m.lhs] = m.desc or ""
end
assert(seen["]t"] == "Next tool call", "]t mapping missing/wrong: " .. tostring(seen["]t"]))
assert(seen["[t"] == "Previous tool call", "[t mapping missing/wrong")
assert(seen["]c"] == "Next thinking block", "]c mapping missing/wrong")
assert(seen["[c"] == "Previous thinking block", "[c mapping missing/wrong")
assert(seen["]e"] == "Next error block", "]e mapping missing/wrong")
assert(seen["[e"] == "Previous error block", "[e mapping missing/wrong")

print("OK nav")

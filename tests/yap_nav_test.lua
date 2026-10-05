local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.fold")

local buf = yap.new()
vim.wo.foldlevel = 99 -- navigation must not be hidden by closed folds
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "",
  "You are helpful.",
  "",
  "# @user",
  "",
  "Q1.",
  "",
  "# @assistant",
  "",
  "<!-- yap:thinking",
  "hmm",
  "-->",
  "",
  "Answer with a tool.",
  "",
  "<!-- yap:tool",
  '{ "id":"c1","name":"bash","arguments":{} }',
  "-->",
  "```",
  "output",
  "```",
  "<!-- /yap:tool -->",
  "",
  "Done.",
  "",
  "# @user",
  "",
  "Q2.",
  "",
  "# @assistant",
  "",
  "<!-- yap:thinking",
  "more",
  "-->",
  "",
  "<!-- yap:error",
  "boom",
  "-->",
  "",
  "Failed.",
  "",
  "# @user",
  "",
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

-- tool or thinking
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.next_tool()
assert(cursor() == think1, "next_tool -> " .. think1 .. ", got " .. cursor())
fold.next_tool()
assert(cursor() == tool1, "next_tool -> " .. tool1 .. ", got " .. cursor())
fold.next_tool()
assert(cursor() == think2, "next_tool -> " .. think2 .. ", got " .. cursor())
fold.next_tool()
assert(cursor() == think2, "next_tool past last block stays put, got " .. cursor())
fold.prev_tool()
assert(cursor() == tool1, "prev_tool -> " .. tool1 .. ", got " .. cursor())
fold.prev_tool()
assert(cursor() == think1, "prev_tool -> " .. think1 .. ", got " .. cursor())
fold.prev_tool()
assert(cursor() == think1, "prev_tool past first block stays put, got " .. cursor())

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
assert(seen["]t"] == "Next tool call or thinking block", "]t mapping missing/wrong: " .. tostring(seen["]t"]))
assert(seen["[t"] == "Previous tool call or thinking block", "[t mapping missing/wrong")
assert(seen["]c"] == "Next thinking block", "]c mapping missing/wrong")
assert(seen["[c"] == "Previous thinking block", "[c mapping missing/wrong")
assert(seen["]e"] == "Next error block", "]e mapping missing/wrong")
assert(seen["[e"] == "Previous error block", "[e mapping missing/wrong")

-- A fenced read result can contain `# @user` and (escaped) yap markers;
-- message navigation must treat them as literal content, not structure.
local buf2 = yap.new()
fold.setup_buffer(buf2)
vim.wo.foldlevel = 99
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, {
  "# @system", "",          -- 1, 2
  "# @user", "",            -- 3, 4
  "# @assistant", "",       -- 5, 6
  '<!-- yap:tool {"id":"c2","name":"read","arguments":{"path":"x.md"}} -->', -- 7
  "```markdown",            -- 8
  "# @user",                -- 9  fake heading, inside the fence
  "\\<!-- yap:thinking",   -- 10 escaped marker, ]t must not land here
  "```",                    -- 11
  "<!-- /yap:tool -->",     -- 12
  "",                       -- 13
  "answer",                 -- 14
  "",                       -- 15
  "# @user", "",            -- 16, 17
})

vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.next_message()
assert(cursor() == 3, "next_message -> 3, got " .. cursor())
fold.next_message()
assert(cursor() == 5, "next_message -> 5, got " .. cursor())
fold.next_message()
assert(cursor() == 16, "next_message skips fake heading -> 16, got " .. cursor())
fold.next_message()
assert(cursor() == 16, "next_message past last stays put, got " .. cursor())
fold.prev_message()
assert(cursor() == 5, "prev_message skips fake heading -> 5, got " .. cursor())
fold.prev_message()
assert(cursor() == 3, "prev_message -> 3, got " .. cursor())

-- ]t still hops to the real tool header, not the escaped marker inside it.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.next_tool()
assert(cursor() == 7, "next_tool -> real header 7, got " .. cursor())
fold.next_tool()
assert(cursor() == 7, "next_tool past only block stays put, got " .. cursor())

-- A thinking block can quote a tool/thinking marker verbatim inside its own
-- fenced content; block navigation must treat it as literal, not a boundary.
local buf3 = yap.new()
fold.setup_buffer(buf3)
vim.wo.foldlevel = 99
vim.api.nvim_buf_set_lines(buf3, 0, -1, false, {
  "# @system", "",                       -- 1, 2
  "# @user", "",                         -- 3, 4
  "# @assistant", "",                    -- 5, 6
  "<!-- yap:thinking",                   -- 7  real thinking opener
  "hmm",                                 -- 8
  "```",                                 -- 9
  '<!-- yap:tool {"id":"x"} -->',       -- 10 literal, inside fence+comment
  "```",                                 -- 11
  "-->",                                 -- 12
  "",                                    -- 13
  "answer",                              -- 14
  "",                                    -- 15
  "# @user", "",                         -- 16, 17
})

vim.api.nvim_win_set_cursor(0, { 17, 0 })
fold.prev_tool()
assert(cursor() == 7, "prev_tool skips marker inside thinking -> 7, got " .. cursor())
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.next_tool()
assert(cursor() == 7, "next_tool -> real thinking 7, got " .. cursor())
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fold.next_think()
assert(cursor() == 7, "next_think -> 7, got " .. cursor())

print("OK nav")

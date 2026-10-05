local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ models = { "mock/m1" } })

local function fresh(lines)
  local buf = yap.new()
  vim.wo.foldlevel = 99 -- unfold everything so cursor line numbers map 1:1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function at(buf, lnum, col)
  vim.api.nvim_win_set_cursor(0, { lnum, col or 0 })
end

-- 1. `dat` removes a whole thinking block (markers included).
do
  local buf = fresh({
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
    "<!-- yap:thinking",
    "some reasoning",
    "more reasoning",
    "-->",
    "",
    "The answer.",
    "",
    "# @user",
    "",
  })
  at(buf, 12, 4) -- inside the thinking content
  vim.cmd.normal("dat")
  local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(not vim.tbl_contains(got, "some reasoning"), "thinking content not deleted")
  assert(not vim.tbl_contains(got, "<!-- yap:thinking"), "thinking opener not deleted")
  assert(not vim.tbl_contains(got, "more reasoning"), "thinking content not deleted")
  assert(vim.tbl_contains(got, "The answer."), "answer deleted too")
end

-- 2. `dit` clears thinking content but keeps the markers.
do
  local buf = fresh({
    "# @user",
    "",
    "Question one.",
    "",
    "# @assistant",
    "",
    "<!-- yap:thinking",
    "some reasoning",
    "more reasoning",
    "-->",
    "",
    "The answer.",
    "",
  })
  at(buf, 7, 4)
  vim.cmd.normal("dit")
  local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(vim.tbl_contains(got, "<!-- yap:thinking"), "opener lost")
  assert(vim.tbl_contains(got, "-->"), "closer lost")
  assert(not vim.tbl_contains(got, "some reasoning"), "inner content not deleted")
end

-- 3. `cim` replaces a message body, keeping the `# @user` heading.
do
  local buf = fresh({
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
    "The answer.",
    "",
    "# @user",
    "",
  })
  at(buf, 7, 3) -- on "Question one."
  vim.api.nvim_feedkeys("cim", "x", false)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(got[5] == "# @user", "user heading lost: " .. vim.inspect(got))
  assert(got[7] == "", "message body not cleared: " .. vim.inspect(got))
  assert(got[9] == "# @assistant", "assistant heading lost: " .. vim.inspect(got))
end

-- 4. `dam` removes a whole message (heading + content + separator).
do
  local buf = fresh({
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
    "The answer.",
    "",
  })
  at(buf, 3, 2) -- inside the system message body
  vim.cmd.normal("dam")
  local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(not vim.tbl_contains(got, "# @system"), "system heading not deleted")
  assert(not vim.tbl_contains(got, "You are helpful."), "system body not deleted")
  assert(got[1] == "# @user", "next message did not become first: " .. vim.inspect(got))
end

-- 5. A fenced read result containing `# @user` must not split the
--    enclosing assistant message: `dam` drops the whole message.
do
  local buf = fresh({
    "# @system", "",
    "You are helpful.", "",
    "# @user", "",
    "Question.", "",
    "# @assistant", "",
    '<!-- yap:tool {"id":"c1","name":"read","arguments":{"path":"x.md"}} -->',
    "```markdown",
    "# @user",                -- fake heading, inside the fence
    "content",
    "```",
    "<!-- /yap:tool -->",
    "",
    "The answer.",
    "",
    "# @user", "",
  })
  at(buf, 13, 0) -- on the fake `# @user` inside the fenced read result
  vim.cmd.normal("dam")
  local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(not vim.tbl_contains(got, "<!-- yap:tool"), "assistant tool header not deleted: " .. vim.inspect(got))
  assert(not vim.tbl_contains(got, "The answer."), "assistant body not deleted: " .. vim.inspect(got))
  -- system and first user survive; the trailing `# @user` is now line 9.
  assert(got[1] == "# @system", "system heading lost: " .. vim.inspect(got))
  assert(got[5] == "# @user", "first user heading lost: " .. vim.inspect(got))
  assert(got[9] == "# @user", "trailing user heading did not land at 9: " .. vim.inspect(got))
end

print("OK textobj")

-- Native za/zo fold opens survive streaming: the reconcile must preserve
-- a fold opened with za (not just yap's <Tab>) across structural appends,
-- while a NEW fold streamed in afterwards still adopts the view's foldlevel
-- (does not inherit the manual open).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.fold")

local function buf_with(lines)
  local buf = yap.new()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  fold.setup_buffer(buf)
  return buf
end

-- 1-based line of the n-th line matching a Lua pattern.
local function find_line(buf, pattern, n)
  n = n or 1
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match(pattern) then
      n = n - 1
      if n == 0 then
        return i
      end
    end
  end
  return nil
end

local function za(buf, lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal! za")
end

-- Append a whole tool region and re-apply folds, exactly as the stream path
-- does when a tool opener lands.
local function append_tool(buf, id)
  local header = ('<!-- yap:tool {"id":"%s","name":"bash","arguments":{}} -->'):format(id)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
    header,
    "result " .. id,
    "<!-- /yap:tool -->",
  })
  fold.after_append(buf, { header })
end

-- ── view 2: za-opened tool survives a streamed tool, new tool stays folded ─
do
  local buf = buf_with({
    "# @system",
    "",
    "sys",
    "",
    "# @user",
    "",
    "Q",
    "",
    "# @assistant",
    "",
    '<!-- yap:tool {"id":"t1","name":"bash","arguments":{}} -->',
    "result one",
    "<!-- /yap:tool -->",
    "",
  })
  fold.set_view_level(2)
  local t1 = find_line(buf, "^<!%-%- yap:tool")
  assert(vim.fn.foldclosed(t1) == t1, "precondition: t1 folded in view 2")
  za(buf, t1)
  assert(vim.fn.foldclosed(t1) == -1, "za did not open t1")
  append_tool(buf, "t2")
  local t2 = find_line(buf, "^<!%-%- yap:tool", 2)
  assert(vim.fn.foldclosed(t1) == -1, "za-opened tool closed on structural append")
  assert(vim.fn.foldclosed(t2) == t2, "new tool fold leaked open: " .. vim.fn.foldclosed(t2))
  print("OK za-opened tool survives, streamed tool stays folded")
end

-- ── view 2: za-opened system prompt survives a streamed tool ─────────────
do
  local buf = buf_with({
    "# @system",
    "",
    "sys",
    "",
    "# @user",
    "",
    "Q",
    "",
    "# @assistant",
    "",
  })
  fold.set_view_level(2)
  assert(vim.fn.foldclosed(1) == 1, "precondition: system folded in view 2")
  za(buf, 1)
  assert(vim.fn.foldclosed(1) == -1, "za did not open the system prompt")
  append_tool(buf, "t1")
  assert(vim.fn.foldclosed(1) == -1, "za-opened system prompt closed on structural append")
  print("OK za-opened system prompt survives in view 2")
end

-- ── view 2: za-opened thinking block survives a streamed tool ────────────
do
  local buf = buf_with({
    "# @system",
    "",
    "sys",
    "",
    "# @user",
    "",
    "Q",
    "",
    "# @assistant",
    "",
    "<!-- yap:thinking",
    "hmm",
    "-->",
    "",
  })
  fold.set_view_level(2)
  local think = find_line(buf, "^<!%-%- yap:thinking")
  assert(vim.fn.foldclosed(think) == think, "precondition: thinking folded in view 2")
  za(buf, think)
  assert(vim.fn.foldclosed(think) == -1, "za did not open the thinking block")
  append_tool(buf, "t1")
  assert(vim.fn.foldclosed(think) == -1, "za-opened thinking closed on structural append")
  print("OK za-opened thinking survives in view 2")
end

-- ── system prompt: folded in views 1 and 2, open in view 3 ───────────────
do
  local buf = buf_with({
    "# @system",
    "",
    "sys",
    "",
    "# @user",
    "",
    "Q",
    "",
  })
  fold.set_view_level(1)
  assert(vim.fn.foldclosed(1) == 1, "system folded in view 1")
  fold.set_view_level(2)
  assert(vim.fn.foldclosed(1) == 1, "system folded in view 2")
  fold.set_view_level(3)
  assert(vim.fn.foldclosed(1) == -1, "system open in view 3")
  print("OK system prompt fold level across views")
end

-- ── view 1: za-opened old assistant survives a new reply ─────────────────
do
  local buf = buf_with({
    "# @system",
    "",
    "sys",
    "",
    "# @user",
    "",
    "Q1",
    "",
    "# @assistant",
    "",
    "A1",
    "", -- old assistant (will za-open)
    "# @user",
    "",
    "Q2",
    "",
  })
  -- The new reply streams in; view 1 keeps all assistant messages folded.
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "# @assistant", "", "A2", "" })
  fold.after_append(buf, { "# @assistant", "" })
  fold.set_view_level(1)
  local old = find_line(buf, "^# @assistant", 1)
  local live = find_line(buf, "^# @assistant", 2)
  assert(vim.fn.foldclosed(old) == old, "precondition: old assistant folded in view 1")
  assert(vim.fn.foldclosed(live) == live, "new assistant should stay folded in view 1")
  za(buf, old)
  assert(vim.fn.foldclosed(old) == -1, "za did not open old assistant")
  -- a new reply should stay folded while the za-opened old assistant stays open
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "# @assistant", "", "A3", "" })
  fold.after_append(buf, { "# @assistant", "" })
  assert(vim.fn.foldclosed(old) == -1, "za-opened old assistant closed on new reply")
  assert(vim.fn.foldclosed(live) == live, "previous reply opened after new reply")
  local newest = find_line(buf, "^# @assistant", 3)
  assert(vim.fn.foldclosed(newest) == newest, "newest reply opened in view 1")
  print("OK za-opened old assistant survives a new reply in view 1")
end

print("OK fold_za")

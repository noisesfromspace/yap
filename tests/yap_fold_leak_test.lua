-- Regression: opening one fold must not leak "open" into folds that stream
-- in afterwards — including when a new fold's opener arrives split across two
-- chunks (the opener's tail completes on a later append). This was the
-- reported "other folds also open" bug.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local fold = require("harness.fold")
local document = require("harness.document")

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
end

-- ── Tab-open a tool, then a thinking block streams in with a split opener ──
do
  local buf = yap.new()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
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
    "result",
    "<!-- /yap:tool -->",
    "",
  })
  fold.setup_buffer(buf)
  fold.set_view_level(2)
  local t1 = find_line(buf, '"t1"')
  fold.open(t1)
  assert(vim.fn.foldclosed(t1) == -1, "precondition: t1 open")

  -- opener tail completes only on the second chunk
  document.append_text(buf, "<!-- yap:thinkin")
  fold.after_append(buf, { "<!-- yap:thinkin" })
  document.append_text(buf, "g\nhmm\n-->\n\n")
  fold.after_append(buf, { "g", "hmm", "-->", "" })

  local th = find_line(buf, "yap:thinking")
  assert(th, "thinking block not found")
  assert(vim.fn.foldclosed(t1) == -1, "Tab-opened tool closed by streamed thinking")
  assert(vim.fn.foldclosed(th) == th, "streamed thinking leaked open: " .. vim.fn.foldclosed(th))
  print("OK tab-open survives split-opener thinking stream")
end

-- ── native za-open a tool, then a second tool streams in whole ─────────────
do
  local buf = yap.new()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
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
  fold.setup_buffer(buf)
  fold.set_view_level(2)
  local t1 = find_line(buf, '"t1"')
  vim.api.nvim_win_set_cursor(0, { t1, 0 })
  vim.cmd("normal! za")
  assert(vim.fn.foldclosed(t1) == -1, "precondition: t1 za-opened")

  -- Hide the session before the next tool streams. Its block cache can
  -- advance while this window has no fold structure to reconcile.
  local enter_count = 0
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      enter_count = enter_count + 1
    end,
  })
  local path = vim.api.nvim_buf_get_name(buf)
  local other = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(other)
  local header = '<!-- yap:tool {"id":"t2","name":"bash","arguments":{}} -->'
  document.append_text(buf, header .. "\nresult two\n<!-- /yap:tool -->")
  fold.after_append(buf, { header })
  local t2 = find_line(buf, '"t2"')

  -- Returning to the hidden session reconciles its window-local manual
  -- folds while retaining t1's explicit open.
  assert(yap.open(path) == buf, "return did not focus the existing session")
  assert(enter_count == 1, "BufWinEnter did not fire on return: " .. enter_count)
  local reconciled = vim.wait(100, function()
    return vim.fn.foldclosed(t2) == t2
  end)
  assert(reconciled, "BufWinEnter did not reconcile the streamed tool fold")
  assert(vim.fn.foldclosed(t1) == -1, "return closed the user-opened fold")
  assert(
    vim.fn.foldclosed(t2) == t2,
    ("return left streamed tool open: closed=%d level=%d end=%d"):format(
      vim.fn.foldclosed(t2),
      vim.fn.foldlevel(t2),
      vim.fn.foldclosedend(t2)
    )
  )
  print("OK hidden-session folds reconcile on return")
  print("OK za-open survives streamed tool")
end

print("OK fold_leak")

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.fold")
local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @user", "", "go", "", "# @assistant", "" })
fold.setup_buffer(buf)
fold.set_view_level(2) -- message folds open, detail folds closed

-- simulate streaming: opener arrives first, close fires, region extends.
-- Manual folds don't auto-appear on edit, so each append drives the same
-- reconcile the real stream path runs (document.append_text + after_append).
local function append(l)
  local row = vim.api.nvim_buf_line_count(buf) - 1
  local col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  vim.api.nvim_buf_set_text(buf, row, col, row, col, vim.split("\n" .. l, "\n", { plain = true }))
  fold.after_append(buf, { l })
end
append("<!-- yap:tool")
append("{")
-- view 2 is foldlevel 2: the new level-3 tool fold closes itself
local opener = 7
assert(vim.fn.foldclosed(opener) == opener, "not closed after opener: " .. vim.fn.foldclosed(opener))
for _, l in ipairs({ '  "id": "w1",', '  "name": "write",', '  "arguments": { "content": "x" }', "}", "-->" }) do
  append(l)
end
assert(vim.fn.foldclosed(opener) == opener, "fold reopened while JSON streamed: " .. vim.fn.foldclosed(opener))
append("Successfully wrote 1 bytes to /tmp/x")
append("<!-- yap:ui")
append("+x")
append("-->")
append("<!-- /yap:tool -->")
assert(vim.fn.foldclosed(opener) == opener, "fold reopened by result lines: " .. vim.fn.foldclosed(opener))
-- the whole region (result, ui, closer) is inside the one fold
local ln = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i, l in ipairs(ln) do
  if l:match("^Successfully") then
    assert(vim.fn.foldclosed(i) == opener, "result line outside the region fold")
  end
  if l:match("^<!%-%- /yap:tool") then
    assert(vim.fn.foldclosed(i) == opener, "region closer outside the fold")
  end
end
print("OK simulation")

-- Regression: a closer followed by a blank line (the real `-->\n\n` /
-- `<!-- /yap:tool -->\n\n` stream) splits the fold's final line; Neovim
-- shrinks the native fold by one line, leaving the closer outside its fold
-- until a later forced rebuild snapped it back. The closer must stay inside
-- the fold on every append, checked via the real document.append_text path.
do
  local document = require("harness.document")
  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf2)
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, {
    "# @system",
    "",
    "sys",
    "",
    "# @user",
    "",
    "go",
    "",
    "# @assistant",
    "",
  })
  fold.setup_buffer(buf2)
  fold.set_view_level(2)

  document.append_text(buf2, "<!-- yap:thinking\n")
  document.append_text(buf2, "let me think\n")
  document.append_text(buf2, "about this\n")

  local opener2
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf2, 0, -1, false)) do
    if l:match("^<!%-%- yap:thinking") then
      opener2 = i
      break
    end
  end
  assert(opener2 and vim.fn.foldclosed(opener2) == opener2, "thinking not folded")

  document.append_text(buf2, "-->\n\n")
  local closer2
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf2, 0, -1, false)) do
    if l:match("^%-%->%s*$") then
      closer2 = i
    end
  end
  assert(closer2, "no closer line found")
  assert(
    vim.fn.foldclosedend(opener2) == closer2,
    "closer fell out of the fold: " .. vim.fn.foldclosedend(opener2) .. " != " .. closer2
  )

  document.append_text(buf2, "Answer text.\n")
  assert(
    vim.fn.foldclosedend(opener2) == closer2,
    "prose append shrank the fold: " .. vim.fn.foldclosedend(opener2) .. " != " .. closer2
  )
  print("OK stream drift")
end

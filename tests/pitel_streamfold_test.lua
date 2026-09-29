local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
local fold = require("harness.fold")
local buf = pitel.new({ provider = "mock", model = "m1" })
vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @user", "", "go", "", "# @assistant", "" })
fold.setup_buffer(buf)
fold.set_view_level(2) -- message folds open, detail folds closed

-- simulate streaming: opener arrives first, close fires, region extends
local function append(l)
  local row = vim.api.nvim_buf_line_count(buf) - 1
  local col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  vim.api.nvim_buf_set_text(buf, row, col, row, col, vim.split("\n" .. l, "\n", { plain = true }))
end
append("<!-- pitel:tool")
append("{")
-- view 2 is foldlevel 2: the new level-3 tool fold closes itself
local opener = 7
assert(vim.fn.foldclosed(opener) == opener, "not closed after opener: " .. vim.fn.foldclosed(opener))
for _, l in ipairs({ '  "id": "w1",', '  "name": "write",', '  "arguments": { "content": "x" }', "}", "-->" }) do
  append(l)
end
assert(vim.fn.foldclosed(opener) == opener, "fold reopened while JSON streamed: " .. vim.fn.foldclosed(opener))
append("Successfully wrote 1 bytes to /tmp/x")
append("<!-- pitel:ui")
append("+x")
append("-->")
append("<!-- /pitel:tool -->")
assert(vim.fn.foldclosed(opener) == opener, "fold reopened by result lines: " .. vim.fn.foldclosed(opener))
-- the whole region (result, ui, closer) is inside the one fold
local ln = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i, l in ipairs(ln) do
  if l:match("^Successfully") then
    assert(vim.fn.foldclosed(i) == opener, "result line outside the region fold")
  end
  if l:match("^<!%-%- /pitel:tool") then
    assert(vim.fn.foldclosed(i) == opener, "region closer outside the fold")
  end
end
print("OK simulation")

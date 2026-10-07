local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
-- mock_write writes a FIXED path; a leftover from a previous run would
-- produce an empty diff (no ui), so clear it to force the create case.
os.remove("/tmp/ml-test.md")
local buf = yap.new({ provider = "mock", model = "m1" })
-- Exercise the user-facing send mapping, not just the M.send() API.
local send = vim.api.nvim_replace_termcodes("<C-s>", true, false, true)
vim.api.nvim_feedkeys(send, "mtx", false)
local ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("File written%.") ~= nil
end, 100)
assert(ok, "send did not complete")
vim.wait(300) -- let the last scheduled chunk handlers run
vim.cmd("silent! 5foldopen") -- open the assistant block like a user would
local opener
for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if l:match("^<!%-%- yap:tool") then
    opener = i
    break
  end
end
assert(opener, "no tool header in buffer")
assert(vim.fn.foldclosed(opener) == opener, "streamed tool fold not closed: " .. vim.fn.foldclosed(opener))
-- write/edit headers are slimmed (R-tool-region): the arguments carry only the
-- shape, not the content (full args are in the audit log)
local header = vim.api.nvim_buf_get_lines(buf, opener - 1, opener, false)[1]
assert(header:match('"content":"%[%d+ lines%]"'), "write header not slimmed: " .. header)
assert(not header:match("line one about dogs"), "slimmed header leaks content: " .. header)
-- the ui diff is a paired-marker + ```diff fence at block level, so
-- treesitter injects the diff parser (not a comment, which wouldn't parse)
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:match("<!%-%- yap:ui %-%->\n```diff"), "ui diff not fenced as diff: " .. text)
assert(text:match("```\n<!%-%- /yap:ui %-%->"), "ui diff fence not closed: " .. text)
print("OK e2e")

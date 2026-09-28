local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
pitel.setup({ bin = ROOT .. "/pitel", provider = "mock", model = "m1" })
local src = vim.fn.tempname() .. ".md"
vim.fn.writefile({
  "# @system", "", "You are helpful.", "",
  "# @user", "", "Question one.", "",
  "# @assistant", "", "Answer one.", "",
  "# @user", "",
}, src)
local buf = pitel.open(src)
local fold = require("harness.fold")
fold.set_view_level(1) -- fold all agent output for this test
local function heading( role, n)
  n = n or 1
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l == "# @" .. role then
      n = n - 1
      if n == 0 then return i end
    end
  end
end
local user1, asst1 = heading("user", 1), heading("assistant", 1)
-- user setup: close a fold that defaults to open, type a prompt
vim.cmd(user1 .. "foldclose")
assert(vim.fn.foldclosed(user1) == user1, "precondition: user fold not closed")
assert(vim.fn.foldclosed(asst1) == asst1, "precondition: assistant fold not closed")
local last_user = heading("user", 2)
vim.api.nvim_buf_set_lines(buf, last_user, last_user + 1, false, { "follow up question" })
local n_before = vim.api.nvim_buf_line_count(buf)
local pre = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
pitel.send()
local ok = vim.wait(8000, function()
  local l = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return l[#l - 1] == "# @user" and (l[#l - 3] or ""):match("slow answer")
end, 100)
assert(ok, "turn did not complete cleanly")
vim.wait(300)
-- 1. fold state preserved across the whole send
assert(vim.fn.foldclosed(user1) == user1, "send reopened a user-closed fold: " .. vim.fn.foldclosed(user1))
assert(vim.fn.foldclosed(asst1) == asst1, "send reopened the assistant fold: " .. vim.fn.foldclosed(asst1))
-- 2. every pre-send line is byte-identical (sends only append)
local post = vim.api.nvim_buf_get_lines(buf, 0, n_before, false)
for i = 1, n_before do
  assert(post[i] == pre[i], ("line %d changed: %q -> %q"):format(i, pre[i], post[i]))
end
-- 3. spacing invariants without any normalize pass
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local joined = table.concat(lines, "\n")
assert(not joined:match("\n\n\n"), "triple newline: " .. joined:sub(-80))
assert(joined:match("arrives in parts%.\n\n# @user\n$"), "bad turn ending: " .. joined:sub(-50))
-- 4. buffer starts at the first heading; usage lives in buffer state
assert(lines[1] == "# @system", "buffer should start with a heading: " .. lines[1])
assert(not joined:match("pitel:usage"), "usage marker left behind")
local u = vim.b[buf].pitel_usage
assert(u and u.prompt == 1500 and u.completion == 42, "usage: " .. vim.inspect(u))
assert(math.abs(u.cost - 0.00342) < 1e-9, "cost: " .. tostring(u.cost))
-- 5. winbar shows combo + usage + state
local wb = pitel.winbar(buf)
assert(wb:match("mock/m1"), "winbar combo: " .. wb)
assert(wb:match("1.5k in · 42 out"), "winbar tokens: " .. wb)
assert(wb:match("%$0.00342"), "winbar cost: " .. wb)
print("OK static")

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/gpt-4o", flash = "" }})
local src = vim.fn.tempname() .. ".md"
vim.fn.writefile({
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
  "Answer one.",
  "",
  "# @user",
  "",
}, src)
local buf = yap.open(src)
local fold = require("harness.ui.fold")
fold.set_view_level(1) -- fold all agent output for this test
local function heading(role, n)
  n = n or 1
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l == "# @" .. role then
      n = n - 1
      if n == 0 then
        return i
      end
    end
  end
end
local user1, asst1 = heading("user", 1), heading("assistant", 1)
-- user setup: open an assistant fold that defaults to folded, type a prompt
vim.cmd(asst1 .. "foldopen")
assert(vim.fn.foldclosed(asst1) == -1, "precondition: assistant fold not opened")
local last_user = heading("user", 2)
vim.api.nvim_buf_set_lines(buf, last_user, last_user + 1, false, { "follow up question" })
local n_before = vim.api.nvim_buf_line_count(buf)
local pre = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
yap.send()
local ok = vim.wait(8000, function()
  local l = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return l[#l - 1] == "# @user" and (l[#l - 3] or ""):match("slow answer")
end, 100)
assert(ok, "turn did not complete cleanly")
vim.wait(300)
-- 1. a send preserves manual fold state: the user's open of asst1 is kept
-- (a send no longer snaps folds back to the view); the new assistant stays
-- folded in view 1.
assert(vim.fn.foldclosed(asst1) == -1, "send discarded the user's open: " .. vim.fn.foldclosed(asst1))
local live = heading("assistant", 2) -- the reply that just streamed in
assert(vim.fn.foldclosed(live) == live, "new assistant not folded in view 1")
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
assert(not joined:match("yap:usage"), "usage marker left behind")
local u = vim.b[buf].yap_usage
assert(u and u.prompt == 1500 and u.completion == 42, "usage: " .. vim.inspect(u))
assert(math.abs(u.cost - 0.00417) < 1e-9, "cost: " .. tostring(u.cost))
print("OK static")

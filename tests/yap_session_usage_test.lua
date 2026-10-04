local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

-- A fresh session has no audit log yet, so no session total until a turn
-- completes and its turn_end journal lands.
local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "hello" })
yap.send()
local ok = vim.wait(10000, function()
  local l = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return l[#l - 1] == "# @user"
end, 100)
assert(ok, "send did not complete")
vim.wait(300)

-- The per-buffer total and the durable session total both landed with the
-- same cost (the turn_end handler folds the event into both copies).
local u = vim.b[buf].yap_usage
assert(u and u.prompt > 0, "no buffer usage: " .. vim.inspect(u))
local su = vim.b[buf].yap_session_usage
assert(su and su.cost and su.cost > 0, "no session usage: " .. vim.inspect(su))
assert(math.abs(su.cost - u.cost) < 1e-9, "session cost != buffer cost: " .. vim.inspect(su))
assert(yap.winbar(buf):match("total %$"), "winbar missing session cost: " .. yap.winbar(buf))

-- Reopen the session (simulating a restart): the totals are seeded from the
-- audit log, so the all-time cost shows without a new turn.
local path = vim.b[buf].yap_path
vim.cmd("bwipeout!")
local reopened = yap.open(path)
local su2 = vim.b[reopened].yap_session_usage
assert(su2 and su2.cost and math.abs(su2.cost - u.cost) < 1e-9, "reopen did not seed session usage: " .. vim.inspect(su2))
assert(yap.winbar(reopened):match("total %$"), "reopened winbar missing session cost: " .. yap.winbar(reopened))
print("OK session_usage")

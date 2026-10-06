-- A blocked call can be inspected repeatedly, with its chat and audit
-- side by side. :only from either window must not strand the user.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })
local chat = yap.new()
vim.api.nvim_buf_set_lines(chat, -1, -1, false, { "try ssh" })
local old_confirm = vim.fn.confirm
local prompts = {}
vim.fn.confirm = function(prompt)
  prompts[#prompts + 1] = prompt
  return #prompts < 4 and 3 or 2 -- Inspect three times, then Deny
end
yap.send()
assert(
  vim.wait(10000, function()
    return #prompts == 1
  end, 50),
  "approval did not prompt: " .. table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), "\n")
)
assert(prompts[1]:find("Inspect", 1, true) and prompts[1]:find("rm -rf /", 1, true), "dialog lacks context")
assert(vim.api.nvim_get_current_buf() == chat, "Inspect should focus the triggering conversation")
assert(
  vim.wait(1500, function()
    local n = vim.api.nvim_win_get_cursor(0)[1]
    return (vim.api.nvim_buf_get_lines(chat, n - 1, n, false)[1] or ""):find("call_approval", 1, true)
  end, 20),
  "Inspect landed away from the triggering tool: "
    .. vim.inspect({ vim.api.nvim_win_get_cursor(0), vim.api.nvim_buf_get_lines(chat, 0, -1, false) })
)
local audit = assert(vim.iter(vim.api.nvim_list_bufs()):find(function(b)
  return vim.api.nvim_buf_get_name(b):match("%-audit$") ~= nil
end))
local audit_win = assert(vim.fn.win_findbuf(audit)[1], "Inspect did not open audit beside chat")
vim.api.nvim_set_current_win(audit_win)
local line = vim.api.nvim_win_get_cursor(0)[1]
local entry = vim.api.nvim_buf_get_lines(audit, line - 1, line, false)[1]
assert(
  entry:find("approval requested", 1, true) and entry:find("rm -rf /", 1, true),
  "Inspect did not show blocked call"
)
assert(vim.fn.foldclosed(line) == -1, "blocked call hidden in fold")
local log = require("harness.path").audit_path(chat)
local function count(event)
  local n = 0
  for _, raw in ipairs(vim.fn.readfile(log)) do
    local ok, ev = pcall(vim.json.decode, raw)
    if ok and ev.type == event then
      n = n + 1
    end
  end
  return n
end
assert(count("approval_result") == 0, "Inspect answered the call")
-- Keep only the audit window: the deferred BufWinLeave cleanup must not
-- replace the approval review with an empty buffer.
vim.cmd("only")
vim.wait(200)
assert(vim.api.nvim_get_current_buf() == audit, ":only from audit lost the review")
vim.cmd("YapApproval") -- Inspect again, restore the conversation beside the audit
assert(#prompts == 2 and vim.api.nvim_get_current_buf() == chat, "Inspect could not be repeated")
assert(vim.fn.win_findbuf(audit)[1], "repeat Inspect did not restore audit")
vim.cmd("only")
assert(vim.api.nvim_get_current_buf() == chat, ":only from chat left an empty buffer")
vim.cmd("YapApproval") -- Inspect again from the chat, then Deny from the audit
assert(#prompts == 3 and vim.api.nvim_get_current_buf() == chat, "third Inspect failed")
vim.api.nvim_set_current_win(assert(vim.fn.win_findbuf(audit)[1]))
vim.cmd("YapApproval")
assert(
  vim.wait(10000, function()
    return count("approval_result") == 1
  end, 50),
  "Deny did not answer"
)
assert(prompts[4]:find("rm -rf /", 1, true), "final dialog lost full arguments")
assert(
  vim.wait(10000, function()
    return table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), "\n"):find("Denied as requested.", 1, true)
  end, 50),
  "turn did not continue after denial"
)
assert(count("approval_request") == 1 and count("approval_result") == 1, "approval trail missing")
vim.fn.confirm = old_confirm
print("OK approval inspect")

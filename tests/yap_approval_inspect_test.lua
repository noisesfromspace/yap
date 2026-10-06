-- A blocked call can be inspected without answering it, then denied from
-- the audit drawer. Both the session and full call remain reviewable.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd('runtime plugin/yap.lua')
local yap = require('harness')
yap.setup({ bin = ROOT .. '/yap', provider = 'mock', model = 'm1' })
local chat = yap.new()
vim.api.nvim_buf_set_lines(chat, -1, -1, false, { 'try ssh' })
local old_confirm = vim.fn.confirm
local prompts = {}
vim.fn.confirm = function(prompt)
  prompts[#prompts + 1] = prompt
  return #prompts == 1 and 3 or 2 -- Inspect, then Deny
end
yap.send()
assert(vim.wait(10000, function() return #prompts == 1 end, 50), 'approval did not prompt: ' .. table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '\n'))
assert(prompts[1]:find('Inspect', 1, true) and prompts[1]:find('rm -rf /', 1, true), 'dialog lacks context')
local audit = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(audit):match('%-audit$'), 'Inspect did not open audit')
local line = vim.api.nvim_win_get_cursor(0)[1]
local entry = vim.api.nvim_buf_get_lines(audit, line - 1, line, false)[1]
assert(entry:find('approval requested', 1, true) and entry:find('rm -rf /', 1, true), 'Inspect did not show blocked call')
assert(vim.fn.foldclosed(line) == -1, 'blocked call hidden in fold')
local log = require('harness.path').audit_path(chat)
local function count(event)
  local n = 0
  for _, raw in ipairs(vim.fn.readfile(log)) do
    local ok, ev = pcall(vim.json.decode, raw)
    if ok and ev.type == event then n = n + 1 end
  end
  return n
end
assert(count('approval_result') == 0, 'Inspect answered the call')
vim.cmd('YapApproval')
assert(vim.wait(10000, function() return count('approval_result') == 1 end, 50), 'Deny did not answer')
assert(prompts[2]:find('rm -rf /', 1, true), 'second dialog lost full arguments')
assert(vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '\n'):find('Denied as requested.', 1, true)
end, 50), 'turn did not continue after denial')
assert(count('approval_request') == 1 and count('approval_result') == 1, 'approval trail missing')
vim.fn.confirm = old_confirm
print('OK approval inspect')

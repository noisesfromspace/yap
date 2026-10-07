-- A `:saveas` copies the session (and its audit log) under a new name and
-- continues in the copy: the original file and audit log stay put, and the
-- copy keeps appending to its own log. Contrast :file (rename), which moves
-- the audit log (see yap_audit_rename_test).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function count(s, pat)
  return select(2, s:gsub(pat, ""))
end

local buf = yap.new()

yap.send()
local ok = vim.wait(10000, function()
  return text(buf):match("File written%.") ~= nil
end, 100)
assert(ok, "first send did not complete")
vim.wait(300)

local old = vim.b[buf].yap_path
local paths = require("harness.path")
local old_audit = paths.audit_path(buf)
assert(vim.fn.filereadable(old_audit) == 1, "audit log not written")

local name = vim.fn.fnamemodify(old, ":t:r") .. "-copy"
local new = vim.fn.fnamemodify(old, ":h:h") .. "/" .. name .. "/" .. name .. ".md"
vim.cmd("saveas " .. vim.fn.fnameescape(new))
vim.wait(200) -- let the deferred rehome run

assert(vim.b[buf].yap_path == new, "yap_path did not follow :saveas")
local new_audit = vim.fn.fnamemodify(new, ":r") .. ".jsonl"
assert(vim.fn.filereadable(old_audit) == 1, "original audit log lost after :saveas")
assert(vim.fn.filereadable(new_audit) == 1, "copied audit log missing after :saveas")

-- The copy's next turn appends to the copy's log; the original stays frozen.
local old_lines = #vim.fn.readfile(old_audit)
local before = count(text(buf), "File written%.")
yap.send()
local ok2 = vim.wait(10000, function()
  return count(text(buf), "File written%.") > before
end, 100)
assert(ok2, "second send did not complete")
vim.wait(300)

assert(vim.fn.filereadable(old_audit) == 1, "original audit log lost after second send")
assert(vim.fn.filereadable(new_audit) == 1, "copied audit log lost after second send")
assert(#vim.fn.readfile(old_audit) == old_lines, "original audit log grew after :saveas (should stay frozen)")
assert(#vim.fn.readfile(new_audit) > old_lines, "copied audit log did not grow after second send")

print("OK saveas")

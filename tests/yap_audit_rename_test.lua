-- The audit log (.jsonl) follows a `:file` rename the same way the
-- session does: renaming the session, then sending (which commits the
-- rename) moves the audit log, and the audit view keeps rendering it.
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
local old_audit = require("harness.path").audit_path(buf)
assert(old_audit and vim.fn.filereadable(old_audit) == 1, "audit log not written")

-- Rename the session the way the user does (:file new-name.md); the next
-- send is what persists the rename and drags the audit log along.
local new = old:gsub("%.md$", "-renamed.md")
vim.api.nvim_buf_set_name(buf, new)

local before = count(text(buf), "File written%.")
yap.send()
local ok2 = vim.wait(10000, function()
  return count(text(buf), "File written%.") > before
end, 100)
assert(ok2, "second send did not complete")
vim.wait(300)

local slug = vim.fs.normalize(vim.fn.getcwd()):gsub("[^%w%._-]", "-")
local want = vim.fn.fnamemodify(new, ":r") .. ".jsonl"
assert(vim.fn.filereadable(old_audit) == 0, "old audit log still exists: " .. old_audit)
assert(vim.fn.filereadable(want) == 1, "renamed audit log missing: " .. want)

-- the audit view still renders the (renamed) audit log
local audit
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):match("%-audit$") then
    audit = b
  end
end
assert(audit, "no audit view buffer")
local audit_text = table.concat(vim.api.nvim_buf_get_lines(audit, 0, -1, false), "\n")
assert(audit_text:match("• write"), "audit view content lost after rename: " .. audit_text)
print("OK audit-rename")

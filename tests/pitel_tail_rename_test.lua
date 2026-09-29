-- The tail sidecar file is created with the session and follows a
-- `:file` rename the same way the session and audit log do: renaming the
-- session, then sending (which commits the rename) moves the tail file.
local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
pitel.setup({ bin = ROOT .. "/pitel", provider = "mock", model = "m1" })

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function count(s, pat)
  return select(2, s:gsub(pat, ""))
end

local buf = pitel.new()
local old_tail = vim.b[buf].pitel_tail_path
assert(old_tail and vim.fn.filereadable(old_tail) == 1, "tail file not created up front")

pitel.send()
local ok = vim.wait(10000, function()
  return text(buf):match("File written%.") ~= nil
end, 100)
assert(ok, "first send did not complete")
vim.wait(300)

-- Rename the session the way the user does (:file new-name.md); the next
-- send is what persists the rename and drags the sidecars along.
local old = vim.b[buf].pitel_path
local new = old:gsub("%.md$", "-renamed.md")
vim.api.nvim_buf_set_name(buf, new)

local before = count(text(buf), "File written%.")
pitel.send()
local ok2 = vim.wait(10000, function()
  return count(text(buf), "File written%.") > before
end, 100)
assert(ok2, "second send did not complete")
vim.wait(300)

local slug = vim.fs.normalize(vim.fn.getcwd()):gsub("[^%w%._-]", "-")
local want_tail = vim.fn.expand("~") .. "/.pitel/audit/" .. slug .. "/"
  .. vim.fn.fnamemodify(new, ":t:r") .. "-tail"
assert(vim.b[buf].pitel_tail_path == want_tail, "tail path did not follow rename: " .. tostring(vim.b[buf].pitel_tail_path))
assert(vim.fn.filereadable(old_tail) == 0, "old tail file still exists: " .. old_tail)
assert(vim.fn.filereadable(want_tail) == 1, "renamed tail file missing: " .. want_tail)
local tail_text = table.concat(vim.fn.readfile(want_tail), "\n")
assert(tail_text:match("• write"), "tail content lost after rename: " .. tail_text)
print("OK tail-rename")

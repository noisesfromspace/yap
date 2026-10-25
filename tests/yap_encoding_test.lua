-- A session file is UTF-8 and must stay UTF-8.
--
-- A tool result that dumped binary (or any other stray byte) makes the file
-- invalid UTF-8, and Nvim's 'fileencodings' then falls back to latin1 when the
-- session is opened again: from that point on every :write re-encodes the WHOLE
-- transcript to latin1, turning each character outside latin1 (— · ─ ✅ …) into
-- a single 0xBF/0xB7 byte. Reopening a session must pin the read to utf-8, so
-- the stray byte is repaired (`?`) instead of latinizing everything written
-- afterwards.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
local session = require("harness.session")

local function read_bytes(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("a")
  f:close()
  return data
end

--- The offsets of bytes that cannot be UTF-8: a continuation byte (0x80..0xBF)
--- where a sequence must start, or a truncated sequence at the end. LuaJIT has
--- no utf8 library and this is the property the test is about, so the walk is
--- spelled out. Continuation bytes of well-formed sequences are skipped, so a
--- `·` (c2 b7) or a ✅ (e2 9c 85) is not a false positive.
local function invalid_bytes(s)
  local i, bad = 1, {}
  while i <= #s do
    local b = s:byte(i)
    local len
    if b < 0x80 then
      len = 1
    elseif b < 0xc0 then
      len = 0 -- a continuation byte outside a sequence
    elseif b < 0xe0 then
      len = 2
    elseif b < 0xf0 then
      len = 3
    else
      len = 4
    end
    if len == 0 or i + len - 1 > #s then
      bad[#bad + 1] = i
      i = i + 1
    else
      i = i + len
    end
  end
  return bad
end

local buf = yap.new()
local path = vim.b[buf].yap_path
session.save(buf)

-- The poison: valid UTF-8 transcript text plus one raw 0xBF byte, exactly as
-- a `head -c` of a binary leaves it.
vim.fn.writefile({ "log — line · here" }, path, "a")
local fd = assert(vim.uv.fs_open(path, "a", 420))
vim.uv.fs_write(fd, "\xbf\n")
vim.uv.fs_close(fd)
assert(#invalid_bytes(read_bytes(path)) == 1, "test setup: stray byte not in the session file")

-- Reopen from disk, as the session picker does.
vim.cmd("silent bwipeout!")
yap.open(path)
buf = vim.api.nvim_get_current_buf()
assert(vim.bo[buf].fileencoding == "utf-8", "reopened session read as " .. vim.bo[buf].fileencoding)
assert(not vim.bo[buf].readonly, "repaired session left 'readonly'")

-- Text appended now must be written as UTF-8, and the repaired-away byte must
-- not come back as part of some other encoding.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "— dash · dot ─ rule ✅" })
session.save(buf)
local bytes = read_bytes(path)
assert(bytes:find("— dash", 1, true), "existing utf-8 content was not preserved")
assert(bytes:find("\xe2\x80\x94 dash", 1, true), "em dash not written as utf-8")
assert(bytes:find("\xc2\xb7 dot", 1, true), "middle dot not written as utf-8")
assert(bytes:find("\xe2\x94\x80 rule", 1, true), "box drawing not written as utf-8")
assert(bytes:find("\xe2\x9c\x85", 1, true), "check mark not written as utf-8")
local bad = invalid_bytes(bytes)
assert(#bad == 0, "session file is not valid utf-8, first stray byte at " .. tostring(bad[1]))

print("OK encoding")

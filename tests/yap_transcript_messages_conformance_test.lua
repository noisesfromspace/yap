-- Conformance: structure.messages_from and the Go document.Messages flatten
-- the same transcript into the same request messages. The cases live in a
-- shared JSON fixture (see agent/document/messages_test.go) so the send-path
-- rules — tool flattening, marker stripping, adjacent-role merging,
-- empty-drop, unclosed-region recovery — cannot drift between runtimes.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local structure = require("harness.model.structure")

local path = ROOT .. "/tests/transcript_messages_cases.json"
local f = io.open(path, "r")
assert(f, "messages conformance fixture not found: " .. path)
local data = f:read("*a")
f:close()

local cases = vim.json.decode(data)
assert(#cases > 0, "messages conformance fixture is empty")

for _, c in ipairs(cases) do
  local lines = vim.split(c.text, "\n", { plain = true })
  local got = structure.messages_from(lines)
  assert(
    vim.deep_equal(got, c.messages),
    c.name .. " mismatch:\n  got=" .. vim.inspect(got) .. "\n  want=" .. vim.inspect(c.messages)
  )
end

print("OK transcript messages conformance")

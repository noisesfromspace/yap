local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local fold = require("harness.fold")

-- Assert fold.fence_run classifies fence openers identically to Go's
-- fenceLine. The cases live in a shared JSON fixture so the two grammars
-- cannot drift apart unnoticed.
local path = ROOT .. "/tests/fence_cases.json"
local f = io.open(path, "r")
assert(f, "fence conformance fixture not found: " .. path)
local data = f:read("*a")
f:close()

local cases = vim.json.decode(data)
assert(#cases > 0, "fence conformance fixture is empty")

for _, c in ipairs(cases) do
  local char, run, tail = fold.fence_run(c.line)
  if c["null"] then
    assert(char == nil, string.format("fence_run(%q) = (%q, %s, %q), want no fence", c.line, char, tostring(run), tail))
  else
    local got = char ~= nil and char or "<nil>"
    assert(
      char == c.char and run == c.run and tail == c.tail,
      string.format(
        "fence_run(%q) = (%q, %s, %q), want (%q, %d, %q)",
        c.line,
        got,
        tostring(run),
        tail,
        c.char,
        c.run,
        c.tail
      )
    )
  end
end

print("OK fence conformance")

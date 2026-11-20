local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local frontmatter = require("harness.model.frontmatter")

-- Assert the Lua frontmatter writer/parser knows the same key set as the Go
-- language-service inventory. The keys live in a shared JSON fixture so the
-- two sides cannot drift apart unnoticed.
local path = ROOT .. "/tests/frontmatter_keys.json"
local f = io.open(path, "r")
assert(f, "frontmatter keys fixture not found: " .. path)
local data = f:read("*a")
f:close()

local keys = vim.json.decode(data)
assert(#keys > 0, "frontmatter keys fixture is empty")

local list_keys = { tools = true }
local map_keys = { previous = true }

-- Build a frontmatter carrying every canonical key, parse it back and assert
-- each key survives, so the Lua writer cannot drift from the Go side.
local lines = { "---" }
for _, k in ipairs(keys) do
  if list_keys[k] then
    lines[#lines + 1] = k .. ":"
    lines[#lines + 1] = "- item"
  elseif map_keys[k] then
    lines[#lines + 1] = k .. ":"
    lines[#lines + 1] = "  key: value"
  elseif k == "turns" then
    lines[#lines + 1] = "turns: 3"
  else
    lines[#lines + 1] = k .. ": value"
  end
end
lines[#lines + 1] = "---"

local fm = frontmatter.parse(lines)
assert(fm, "frontmatter with all canonical keys must parse")

for _, k in ipairs(keys) do
  if k == "turns" then
    assert(fm.turns == 3, "turns not recovered: " .. vim.inspect(fm.turns))
  elseif list_keys[k] then
    local v = fm[k]
    assert(v and #v == 1 and v[1] == "item", k .. " list not recovered: " .. vim.inspect(v))
  elseif map_keys[k] then
    local v = fm[k]
    assert(v and vim.tbl_count(v) == 1 and v["key"] == "value", k .. " map not recovered: " .. vim.inspect(v))
  else
    assert(fm[k] == "value", k .. " not recovered: " .. vim.inspect(fm[k]))
  end
end

print("OK frontmatter keys conformance")

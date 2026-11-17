-- The session picker tree shows each row's state: a subagent row carries its
-- own state glyph where its type glyph used to be, and the picker no longer
-- has a robot icon to configure.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ model_groups = { agent = "mock/m1", flash = "" } })
assert(yap.config.icons.agent == nil, "subagent type glyph should be gone")
local picker = require("harness.ui.picker")
local glyphs = picker.glyphs()
local session = require("harness.session")
local frontmatter = require("harness.model.frontmatter")

local parent = yap.new()
local parent_path = vim.b[parent].yap_path
local child = yap.new({ agent = "scout", hidden = true, system = "Scout agent", tools = { "read" } })
vim.b[child].yap_subagent_parent = parent
vim.b[child].yap_subagent_task = "scan the tree"
frontmatter.update(child, { subagent_parent = vim.fn.fnamemodify(parent_path, ":h") })
session.save(child)

local function rows()
  local captured
  vim.ui.select = function(items, opts)
    captured = { items = items, format = opts.format_item }
  end
  yap.sessions()
  local out = {}
  for _, item in ipairs(captured.items) do
    out[item.child_kind or "root"] = captured.format(item)
  end
  return out
end

local shown = rows()
local agent_row = assert(shown.agent, "subagent row missing from the picker: " .. vim.inspect(shown))
assert(agent_row:find("─ " .. glyphs.idle .. " ", 1, true), "subagent row lacks its state glyph: " .. agent_row)
assert(not agent_row:find("^" .. glyphs.idle), "state glyph still in the status column: " .. agent_row)
local state = require("harness.state")
state.running[child] = {}
local running_row = rows().agent
assert(
  running_row:find("─ " .. glyphs.running .. " ", 1, true),
  "running subagent row lacks the running glyph: " .. running_row
)
state.running[child] = nil
vim.api.nvim_buf_delete(child, { unload = true })
local closed_row = assert(rows().agent, "closed subagent missing from the picker")
local closed_item = vim.iter(session.list()):find(function(item)
  return item.child_kind == "agent"
end)
assert(
  closed_row == picker.prefix(nil, picker.icon_width(glyphs)) .. closed_item.rail .. closed_item.text,
  "closed subagent should show no status glyph: " .. closed_row
)
print("OK picker tree")

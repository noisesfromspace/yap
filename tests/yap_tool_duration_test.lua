-- A long bash call records a tool_duration marker after its tool region; the
-- parser attaches it to the tool fold and the closed fold label shows the
-- wall-clock duration. Pure state, no provider traffic.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local fold = require("harness.ui.fold")
local structure = require("harness.model.structure")

-- Render a fold label to plain text for readable assertions (the colored
-- chunks concatenate in order).
local function flat(label)
  if type(label) == "string" then
    return label
  end
  local out = {}
  for _, c in ipairs(label) do
    out[#out + 1] = c[1]
  end
  return table.concat(out)
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant",
  "",
  '<!-- yap:tool {"id":"b1","name":"bash","arguments":{}} -->',
  "ok result",
  "<!-- /yap:tool -->",
  '<!-- yap:event {"type":"tool_duration","name":"bash","ms":42000} -->',
  "",
})

local p = structure.parse(buf)
assert(#p.tool_durations == 1, "tool_durations: " .. #p.tool_durations)
local d = p.tool_durations[1]
assert(d.tool_start == 3 and d.ms == 42000, vim.inspect(d))

-- The duration marker folds into the tool, so it is not visible prose.
local tool = p.regions[1]
assert(tool.kind == "tool" and tool.fold_finish == 6, "tool fold did not grow: " .. vim.inspect(tool))

-- The closed tool fold shows the duration next to the tool name.
assert(flat(fold.text(3, 6)) == "▸ tool: bash · 42s", "foldtext: " .. vim.inspect(fold.text(3, 6)))

-- Minutes render as m + padded seconds; hours render as h + minutes.
local minutes = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(minutes)
vim.api.nvim_buf_set_lines(minutes, 0, -1, false, {
  '<!-- yap:tool {"id":"b2","name":"bash"} -->',
  "r",
  "<!-- /yap:tool -->",
  '<!-- yap:event {"type":"tool_duration","name":"bash","ms":65000} -->',
})
assert(flat(fold.text(1, 4)) == "▸ tool: bash · 1m 05s (4 lines)", "foldtext: " .. vim.inspect(fold.text(1, 4)))

-- A tool without a duration marker keeps its plain label.
local plain = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(plain)
vim.api.nvim_buf_set_lines(plain, 0, -1, false, {
  '<!-- yap:tool {"id":"b3","name":"bash"} -->',
  "r",
  "<!-- /yap:tool -->",
  "",
})
assert(fold.text(1, 3) == "▸ tool: bash", "foldtext: " .. vim.inspect(fold.text(1, 3)))

print("OK tool duration")

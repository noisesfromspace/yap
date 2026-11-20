-- The symbol picker suffixes the events that name a reply: a stopped turn and
-- an accepted cost warning. The suffix comes from the same parser that renders
-- the fold badges, so a message symbol and its closed-fold label agree.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })
local lsp = require("harness.client.lsp")
local structure = require("harness.model.structure")

local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "",
  "system",
  "",
  "# @user",
  "",
  "first question",
  "",
  "# @assistant",
  "",
  "first answer",
  "",
  '<!-- yap:event {"type":"turn_stopped","text":"Turn stopped","ts":"2026-11-20T10:00:00Z","outcome":"stopped"} -->',
  "",
  "# @user",
  "",
  "second question",
  "",
  '<!-- yap:event {"type":"cost_override","text":"Cost warning accepted","ts":"2026-11-20T10:01:00Z"} -->',
  "",
  "# @assistant",
  "",
  "second answer",
  "",
  "# @user",
  "",
  "third question",
  "",
  "# @assistant",
  "",
  "third answer",
  "",
  '<!-- yap:event {"type":"turn_stopped","text":"Turn force-stopped","ts":"2026-11-20T10:02:00Z","outcome":"killed"} -->',
  "",
})

-- The parser attaches each event to its owning assistant heading. A stop
-- marker inside a reply belongs to that reply; a cost override in the user
-- block belongs to the reply that follows.
local by_kind = {}
for _, ev in ipairs(structure.parse(buf).events) do
  by_kind[ev.kind .. "/" .. (ev.outcome or "")] = ev
end
assert(by_kind["turn_stopped/stopped"].assistant == 9, "graceful stop attached to the wrong reply")
assert(by_kind["cost_override/"].assistant == 21, "cost override attached to the wrong reply")
assert(by_kind["turn_stopped/killed"].assistant == 29, "force-stop attached to the wrong reply")

-- The LSP outline is stubbed; the suffix comes from the local parser.
lsp.symbols = function()
  return {
    { name = "assistant: third answer", line = 29 },
    { name = "assistant: second answer", line = 21 },
    { name = "assistant: first answer", line = 9 },
  }
end

local captured
local orig_select = vim.ui.select
vim.ui.select = function(items)
  captured = items
end
yap.symbols(buf)
vim.ui.select = orig_select

local function name_at(line)
  for _, item in ipairs(captured) do
    if item.line == line then
      return item.name
    end
  end
end
assert(name_at(9) == "assistant: first answer  [Stopped]", "stop suffix missing: " .. tostring(name_at(9)))
assert(name_at(21) == "assistant: second answer  [Cost override]", "cost suffix missing: " .. tostring(name_at(21)))
assert(
  name_at(29) == "assistant: third answer  [Force-stopped]",
  "force-stop suffix missing: " .. tostring(name_at(29))
)
assert(#captured == 3, "symbol count changed")

print("OK symbol badges")

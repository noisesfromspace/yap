-- Treesitter highlight policy: mode resolution and the full<->block downgrade
-- as a session grows and shrinks. The injection mutation itself is exercised
-- only where a markdown parser is available; mode/flag logic is parser-free.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local highlight = require("harness.session.highlight")

yap.setup({
  bin = ROOT .. "/yap",
  syntax_highlight = true,
  syntax_highlight_block_lines = 10,
})

local buf = yap.new({ provider = "mock", model = "m1" })
-- Pin the buffer to a known small size so the threshold test is deterministic
-- regardless of how long the default system prompt is.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @system", "", "sys", "", "# @user", "" })

-- A fresh session is small: full mode.
assert(highlight.mode(buf) == "full", "small session should be full")
highlight.apply(buf)
assert(vim.b[buf].yap_highlight_mode == "full", "flag should be full")

-- Re-applying is a no-op (cheap on every append).
highlight.apply(buf)
assert(vim.b[buf].yap_highlight_mode == "full", "re-apply should be a no-op")

-- Growing past the threshold downgrades to block.
local big = {}
for i = 1, 20 do
  big[i] = "line " .. i
end
vim.api.nvim_buf_set_lines(buf, -1, -1, false, big)
assert(highlight.mode(buf) == "block", "large session should downgrade to block")
highlight.apply(buf)
assert(vim.b[buf].yap_highlight_mode == "block", "flag should be block")

-- Shrinking back under the threshold restores full (the :YapCompact path).
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @system", "", "sys", "", "# @user", "" })
assert(highlight.mode(buf) == "full", "shrunk session should restore full")
highlight.apply(buf)
assert(vim.b[buf].yap_highlight_mode == "full", "flag should restore to full")

-- Explicit modes win over the line-count heuristic.
yap.config.syntax_highlight = "block"
assert(highlight.mode(buf) == "block", '"block" config should force block mode')
yap.config.syntax_highlight = false
assert(highlight.mode(buf) == "none", "false config should mean no highlighting")
yap.config.syntax_highlight = true

print("OK highlight")

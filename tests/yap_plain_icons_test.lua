-- Explicit plain-Unicode mode works even when the terminal cannot report font support.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ nerd_font = false, provider = "mock", model = "m1", icons = { steer = "→" } })
local icons = yap.config.icons
assert(icons.running == "▶" and icons.stopped == "⏹" and icons.error == "✗" and icons.waiting == "◉")
assert(icons.idle == "○" and icons.approval == "⚠")
assert(icons.since == "" and icons.total == "" and icons.steer == "→")
local state = require("harness.state")
local buf, other = yap.new(), vim.api.nvim_create_buf(false, true)
vim.b[other].yap = true
state.sessions[other] = true
state.awaiting[other] = true
local bar = yap.winbar(buf)
local rendered = vim.api.nvim_eval_statusline(bar, { winid = 0, use_winbar = true, maxwidth = 200 }).str
assert(rendered:find("[ ◉1 ]", 1, true), "plain island missing: " .. rendered)
assert(yap.overview(buf) == "◉1")
state.last_turn[buf] = { prompt = 23000, context_window = 250000 }
bar = yap.winbar(buf)
assert(bar:find("▊", 1, true) and bar:find("░", 1, true), "plain gauge missing: " .. bar)
assert(not bar:find("", 1, true), "Nerd Font gauge in plain mode: " .. bar)
state.running[buf] = {}
bar = yap.winbar(buf)
assert(bar:find("※", 1, true), "plain spinner missing: " .. bar)
assert(not bar:find("󰫢", 1, true), "Nerd Font spinner in plain mode: " .. bar)
state.running[buf] = nil
state.awaiting[other] = nil
print("OK plain_icons")

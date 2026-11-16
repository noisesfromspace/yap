-- The pre-send cost guard and the picker's rate preview (R-cost-guard).
--
-- Pure state: no provider traffic. The price map is seeded through the same
-- JSON cache the backend writes, so this pins the decoding as well as the
-- arithmetic.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "openai/gpt-6-astra", flash = "" } })

local config = require("harness.config")
local costguard = require("harness.client.costguard")
local state = require("harness.state")

-- Seed the sibling price cache exactly as refresh_models writes it.
local cache = vim.fn.stdpath("cache") .. "/yap"
vim.fn.mkdir(cache, "p")
vim.fn.writefile({ "openai/gpt-6-astra", "openai/gpt-6-sol" }, cache .. "/models")
vim.fn.writefile({
  '[{"name":"openai/gpt-6-astra","input":10,"output":50,"cache_read":1,"context":922000},',
  ' {"name":"openai/gpt-6-sol","input":2,"output":10,"cache_read":0.2,"context":922000},',
  ' {"name":"mystery/model","input":0,"output":0,"cache_read":0,"context":0}]',
}, cache .. "/models.json")
config.load_models_cache()

-- Decoding: the catalog's rates reach the picker.
local astra = assert(config.model_price("openai/gpt-6-astra"), "astra price not decoded")
assert(astra.input == 10 and astra.output == 50 and astra.cache_read == 1)
assert(config.model_price("nope/model") == nil, "unknown combo reported a price")

-- The preview carries the rate and the window; the row stays the bare combo.
local preview = assert(config.model_preview("openai/gpt-6-astra"))
local text = table.concat(preview, "\n")
assert(text:find("$10 in", 1, true) and text:find("$50 out", 1, true), "rate missing from preview: " .. text)
assert(text:find("$1 per 1M cached", 1, true), "cache rate missing from preview: " .. text)
assert(text:find("922k context", 1, true), "context window missing from preview: " .. text)
assert(config.model_preview("mystery/model"), "an unpriced combo should still preview")
assert(not table.concat(config.model_preview("mystery/model"), "\n"):find("%$"), "invented a price")
assert(config.model_preview("nope/model") == nil, "unknown combo previewed a price")

-- Pick passes a lean title and a preview hook to vim.ui.select.
local picked
local orig_select = vim.ui.select
vim.ui.select = function(items, opts, cb)
  picked = { items = items, opts = opts }
  cb(items[1])
end
local chosen
config.pick(function(c) chosen = c end)
vim.ui.select = orig_select
assert(picked.opts.format_item("openai/gpt-6-astra") == "openai/gpt-6-astra", "row must stay the bare combo")
assert(picked.opts.preview_item, "picker must offer a preview_item")
assert(chosen == "openai/gpt-6-astra")

-- Guard arithmetic: context x 2 steps x uncached input rate.
assert(math.abs(costguard.estimate("openai/gpt-6-astra", 240000) - 4.8) < 0.001, "astra estimate wrong")
assert(math.abs(costguard.estimate("openai/gpt-6-sol", 240000) - 0.96) < 0.001, "sol estimate wrong")
assert(costguard.estimate("mystery/model", 240000) == nil, "unpriced model must not estimate")
assert(costguard.estimate("openai/gpt-6-astra", 0) == nil, "no context, no estimate")

-- Context comes from the last turn when the backend has reported one.
local buf = yap.new({ provider = "openai", model = "gpt-6-astra" })
state.last_turn[buf] = { context_prompt = 240000 }
assert(costguard.context_tokens(buf, {}) == 240000)
state.last_turn[buf] = nil
assert(costguard.context_tokens(buf, { { content = string.rep("x", 4000) } }) == 1000, "chars/4 fallback")

-- A cheap turn passes without asking.
local asked = 0
local orig_ask = costguard.ask
costguard.ask = function()
  asked = asked + 1
end
config.price_guard = { enabled = true, max_usd = 2.0 }
state.last_turn[buf] = { context_prompt = 10000 } -- sol-priced astra? 10k x 10 x 2 = $0.2
assert(costguard.check(buf, "openai/gpt-6-astra", {}) == true, "cheap turn blocked")
assert(asked == 0, "cheap turn asked")

-- An expensive turn parks the send and asks exactly once.
state.last_turn[buf] = { context_prompt = 240000 }
assert(costguard.check(buf, "openai/gpt-6-astra", {}) == false, "expensive turn was not parked")
assert(asked == 1, "expensive turn did not ask")

-- "Send anyway" approves that model for the session: a second identical send
-- passes silently, and the send it re-enters is not the one that asked.
vim.b[buf].yap_cost_approved = "openai/gpt-6-astra"
assert(costguard.check(buf, "openai/gpt-6-astra", {}) == true, "approval did not stick")
assert(asked == 1, "asked twice for the same model")
-- Switching model re-arms the guard, because the approval is keyed by combo.
assert(costguard.check(buf, "openai/gpt-6-sol", {}) == true, "a cheaper model should pass")
vim.b[buf].yap_cost_approved = nil
assert(costguard.check(buf, "openai/gpt-6-astra", {}) == false, "switch did not re-arm the guard")

-- A subagent is never blocked: nobody could answer.
assert(costguard.check(buf, "openai/gpt-6-astra", {}, true) == true, "subagent was blocked")

-- The guard is off when disabled, and silent on models with no catalog entry.
config.price_guard = { enabled = false, max_usd = 2.0 }
assert(costguard.check(buf, "openai/gpt-6-astra", {}) == true, "disabled guard still blocked")
config.price_guard = { enabled = true, max_usd = 2.0 }
assert(costguard.check(buf, "mystery/model", {}) == true, "unpriced model was blocked")

costguard.ask = orig_ask

-- Refresh writes both caches from one `yap models --json` call: the plain list
-- the LSP reads, and the sibling price map this module decodes. A fake bin
-- keeps it offline.
local bindir = vim.fn.tempname()
vim.fn.mkdir(bindir, "p")
local fake = bindir .. "/yap"
vim.fn.writefile({
  "#!/bin/sh",
  "printf '[{\"name\":\"fake/m1\",\"input\":7,\"output\":9,\"cache_read\":0.7,\"context\":1000}]'",
}, fake)
vim.fn.setfperm(fake, "rwxr-xr-x")
vim.fn.delete(cache .. "/models")
vim.fn.delete(cache .. "/models.json")
yap.config.bin = fake
-- A discovery may already be in flight from setup(); refresh_models is a no-op
-- while one runs, so retry from the wait predicate until the fake bin lands.
local settled = vim.wait(20000, function()
  config.refresh_models()
  return config.model_price("fake/m1") ~= nil
end, 50)
assert(settled, "refresh never wrote the price cache")
assert(vim.fn.readfile(config.models_cache_path())[1] == "fake/m1", "plain list cache not written")
local refreshed = assert(config.model_price("fake/m1"), "price cache not written")
assert(refreshed.input == 7 and refreshed.output == 9 and refreshed.cache_read == 0.7)

-- Wiring: send() consults the guard before it writes anything, and a parked
-- send reports false without mutating the buffer (R-cost-guard). Patching the
-- guard's own table is enough because send() looks the field up at call time.
local stream = require("harness.client.stream")
local orig_check = costguard.check
local consulted = false
costguard.check = function()
  consulted = true
  return false
end
local wired = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(wired, -1, -1, false, { "# @user", "", "hello" })
local parked = stream.send(wired)
costguard.check = orig_check
assert(consulted, "send() did not consult the cost guard")
assert(parked == false, "a parked send must report false")
assert(
  not table.concat(vim.api.nvim_buf_get_lines(wired, 0, -1, false), "\n"):find("# @assistant", 1, true),
  "a parked send appended an assistant heading"
)

print("OK costguard")

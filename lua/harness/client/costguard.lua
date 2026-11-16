-- The pre-send cost guard: at most one confirmation before a turn that would
-- be expensive, then silence for the rest of the session. It is a speed bump,
-- not a policy: the alternative is a subscription window spent on a turn
-- nobody meant to run (see R-cost-guard).
--
-- The estimate errs high on purpose. It assumes every model step re-sends the
-- whole context at the uncached input rate, which is what a tool-heavy turn
-- does and what a route that reports no cache does. Caching only ever makes
-- the real bill smaller, so a turn under the threshold is genuinely cheap.

local M = {}

local state = require("harness.state")
local config = require("harness.config")

-- Steps assumed per turn: one tool round trip, the common shape. A longer
-- agentic turn costs more than the estimate; the winbar and audit report what
-- was actually spent.
local STEPS = 2

-- The approval lives in a buffer variable, so it dies with the buffer instead
-- of leaking into a reused buffer number.
local APPROVED = "yap_cost_approved"

--- Worst-case US-dollar cost of one turn with `ctx` tokens of context on
--- `combo`, or nil when the catalog has no entry (never guess a price).
function M.estimate(combo, ctx)
  local info = config.model_price(combo)
  local input = info and tonumber(info.input) or 0
  if input <= 0 or not ctx or ctx <= 0 then
    return nil
  end
  return ctx * STEPS * input / 1e6
end

--- Context size to price: the last turn's real prompt when there is one, else
--- a byte estimate of what is about to be sent. The message list is the same
--- one `send()` already asked the backend for.
function M.context_tokens(buf, messages)
  local last = state.last_turn[buf]
  local known = last and tonumber(last.context_prompt) or 0
  local chars = 0
  for _, m in ipairs(messages or {}) do
    chars = chars + #(m.content or "")
  end
  return math.max(known, math.floor(chars / 4))
end

--- True when this send may proceed. False parks it: `ask` has already opened
--- the confirmation, and choosing "send anyway" re-enters the send.
--- `unattended` is true for a subagent, which is never blocked.
function M.check(buf, combo, messages, unattended)
  local cfg = config.price_guard or {}
  if unattended or cfg.enabled == false then
    return true
  end
  local limit = tonumber(cfg.max_usd) or 0
  if limit <= 0 then
    return true
  end
  local ctx = M.context_tokens(buf, messages)
  local cost = M.estimate(combo, ctx)
  if not cost or cost < limit then
    return true
  end
  if vim.b[buf][APPROVED] == combo then
    return true
  end
  M.ask(buf, combo, ctx, cost)
  return false
end

--- Ask about one turn. "Send anyway" covers the rest of the session for this
--- model, so a repeated expensive turn does not nag; switching model re-arms
--- the guard, because the approval is keyed by combo.
function M.ask(buf, combo, ctx, cost)
  local question =
    string.format("%s · %s context × %d steps ≈ $%.2f", combo, require("harness.util").fmt_tokens(ctx), STEPS, cost)
  vim.ui.select({ "Send anyway", "Switch model…", "Cancel" }, { prompt = question }, function(choice)
    if choice == "Send anyway" then
      vim.b[buf][APPROVED] = combo
      require("harness.client.stream").send(buf)
    elseif choice == "Switch model…" then
      require("harness").change_model(nil)
    end
  end)
end

return M

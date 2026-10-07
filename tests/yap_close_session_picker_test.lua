-- E2E: close_session while the session picker (vim.ui.select's default
-- inputlist prompt) is open. The command-line prompt keeps the session as
-- the current buffer while the user is really in the picker, so the landing
-- logic must NOT redirect to another session — the close should be as quiet
-- as a background turn.
--
-- Unlike the other headless suites this one needs a *blocking* command-line
-- prompt (inputlist) so `getcmdtype()` is non-empty while the turn finishes,
-- so it runs via `+lua dofile` rather than `nvim -l` (see tests/run.sh).
-- `+lua` swallows errors into the UI, so failures exit explicitly.
local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local state = require("harness.state")
yap.setup({ bin = ROOT .. "/yap", provider = "mock", model = "m1" })

local function current()
  return vim.api.nvim_get_current_buf()
end

local function set_prompt(b, text)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i] == "# @user" then
      vim.api.nvim_buf_set_lines(b, i, -1, false, { text })
      return
    end
  end
end

-- A waiting session to land on if the redirect logic fires (it must not).
local waiting = yap.new()
state.awaiting[waiting] = true

local buf = yap.new()
set_prompt(buf, "when you are done, close the session")
yap.send()

-- Open the real inputlist picker and keep it open until the close fires.
-- The prompt blocks but still processes scheduled/job callbacks, so the
-- turn completes (and close_session wipes the buffer) while it is open.
local close_happened_in_picker = false
local function cancel_when_closed(deadline)
  if not vim.api.nvim_buf_is_valid(buf) then
    close_happened_in_picker = true
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "t", false)
  elseif os.time() > deadline then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "t", false)
  else
    vim.defer_fn(function()
      cancel_when_closed(deadline)
    end, 20)
  end
end
vim.defer_fn(function()
  cancel_when_closed(os.time() + 30)
end, 20)
vim.fn.inputlist({ "yap sessions", "1: waiting", "2: current" })

if not close_happened_in_picker then
  fail("close_session did not complete while the picker was open")
end
if current() == waiting then
  fail("close_session redirected to the waiting session while the picker was open")
end
if not vim.b[waiting].yap then
  fail("waiting session should still be open")
end
print("OK close_session picker")

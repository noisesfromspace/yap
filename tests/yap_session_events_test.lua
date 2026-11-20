local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ model_groups = { agent = "mock/m1", flash = "" } })
local costguard = require("harness.client.costguard")
local document = require("harness.model.document")

local function markers(buf)
  local out = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local json = line:match("^<!%-%- yap:event (.*) %-%->$")
    if json then
      local marker = vim.json.decode(json)
      assert(marker.ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"), line)
      marker.line = i
      assert(not out[marker.type], "duplicate " .. marker.type)
      out[marker.type] = marker
    end
  end
  return out
end

local function prompt(buf, text)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { text })
end

local function wait_turn(buf)
  assert(yap.is_running(buf), "turn did not start")
  assert(vim.wait(10000, function()
    return not yap.is_running(buf)
  end), "turn did not finish")
  assert(not require("harness.state").errors[buf], "turn failed")
end

local buf = yap.new()
local path = vim.b[buf].yap_path
local first_cwd = vim.fn.getcwd()
prompt(buf, "first prompt")
yap.send(buf)
wait_turn(buf)
yap.open(path)
assert(not next(markers(buf)), "refocusing a loaded session left a trace")

vim.cmd("enew")
vim.api.nvim_buf_delete(buf, { force = true })
yap.open(path)
buf = vim.api.nvim_get_current_buf()
assert(not next(markers(buf)), "opening a saved session left a trace")
yap.change_model("mock/m2")
yap.change_model("mock/m3")
local cwd = vim.fn.tempname()
vim.fn.mkdir(cwd, "p")
vim.cmd.lcd(cwd)
prompt(buf, "second prompt")

local original_select = vim.ui.select
vim.ui.select = function(_, _, answer)
  answer("Cancel")
end
costguard.ask(buf, "mock/m3", 100, 1.25)
assert(not next(markers(buf)) and not yap.is_running(buf), "declining a cost warning left a trace")
vim.ui.select = function(_, _, answer)
  answer("Send anyway")
end
costguard.ask(buf, "mock/m3", 100, 1.25)
vim.ui.select = original_select
wait_turn(buf)

local events = markers(buf)
assert(events.session_resumed)
assert(events.model_change.from == "mock/m1" and events.model_change.to == "mock/m3")
assert(events.cwd_change.from == first_cwd and events.cwd_change.to == cwd)
assert(events.cost_override.combo == "mock/m3" and events.cost_override.estimate_usd == 1.25)
assert(vim.api.nvim_buf_get_lines(buf, events.cost_override.line + 1, events.cost_override.line + 2, false)[1] == "# @assistant")
for _, message in ipairs(assert(document.messages(buf))) do
  assert(not message.content:find("yap:event", 1, true), "event leaked into conversation")
end

prompt(buf, "third prompt")
yap.send(buf)
wait_turn(buf)
markers(buf) -- no duplicate resume, cwd, model, or cost event
print("OK session events")

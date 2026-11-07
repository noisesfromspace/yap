local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
package.loaded.harness = nil -- start-packages may have loaded the installed copy before this test prepended the repo
local yap = require("harness")
local frontmatter = require("harness.model.frontmatter")
local paths = require("harness.path")
yap.setup({
  bin = ROOT .. "/yap",
  model_groups = { agent = "mock/m1", flash = "mock/m1" },
})

local log_path = "/tmp/yap-describe.log"
os.remove(log_path)

local buf = yap.new({ provider = "mock", model = "m1" })
-- Reproduce the common title failure: a substantive task followed by the
-- routine end-of-session commit instruction.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
  "Fix the session picker label",
  "# @assistant",
  "Implemented the picker label fix.",
  "# @user",
  "Commit changes from this session and ignore unrelated changes, potentially another AI session made those. If this completes the requests of the user use the close tool to close the session",
})
yap.send()

local ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("described%.") ~= nil
end, 100)
assert(ok, "send did not complete")

local function read_log()
  local f = io.open(log_path, "r")
  if not f then
    return ""
  end
  local text = f:read("*a")
  f:close()
  return text
end

-- Wait until the completion-title request has been logged.
ok = vim.wait(10000, function()
  local text = read_log()
  return text:match("user's request") and text:match("centered on the overall work")
end, 100)
assert(ok, "description requests missing from log: " .. read_log())

local tiny, full
for line in read_log():gmatch("[^\n]+") do
  local ok, decoded = pcall(vim.json.decode, line)
  if ok and type(decoded) == "table" and type(decoded.messages) == "table" then
    local system = decoded.messages[1] and decoded.messages[1].content or ""
    if system:match("Write a short title for the user's request") then
      tiny = line
    elseif system:match("centered on the overall work") then
      full = line
    end
  end
end

assert(tiny and tiny:match("Fix the session picker label"), "instant title missing initial request: " .. tostring(tiny))
assert(not tiny:match("Commit changes from this session"), "instant title used the commit footer: " .. tiny)

-- The answer title sees the task requests, but excludes assistant transcript/tool output.
assert(full and full:match("Fix the session picker label"), "overall title missing initial request: " .. tostring(full))
assert(
  not full:match("described%.") and not full:match("Implemented the picker label fix"),
  "assistant content leaked into title input: " .. full
)
assert(
  full:match("Commit changes from this session"),
  "routine commit footer missing from title input (the model prompt, not a filter, classifies it): " .. full
)
assert(
  full:match("housekeeping"),
  "answer title prompt missing the housekeeping rule: " .. full
)
assert(
  full:match("first request anchors the session's main goal"),
  "overall title prompt does not anchor the first request: " .. full
)
assert(not full:match("Subject: change"), "answer title prompt still requests the colon pattern: " .. full)
assert(full:match("No colon"), "answer title prompt missing colon guard: " .. full)

-- The title model must be tool-less: a model that keeps the full tool set
-- can execute the user's request instead of returning a title (an imperative
-- request like "count to 10" makes a reasoning model run `bash`). With
-- `tools = {}` the backend sends the provider no tool definitions, so the
-- request carries no `tools` key at all — and an attempted call comes back as
-- plain-text markup, which the flat-phrase guard rejects (see the tool-call
-- regression case below).
for line in read_log():gmatch("[^\n]+") do
  local ok, decoded = pcall(vim.json.decode, line)
  if ok and type(decoded) == "table" and type(decoded.messages) == "table" then
    local system = decoded.messages[1] and decoded.messages[1].content or ""
    if system:match("Write a short title") or system:match("centered on the overall work") then
      assert(decoded.tools == nil, "title request must not send tools: " .. line)
    end
  end
end

-- The requests are logged before their replies complete. Wait for the
-- asynchronous description callback to update the frontmatter.
ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, 8, false), "\n"):match("description: described%.") ~= nil
end, 50)
local lines = vim.api.nvim_buf_get_lines(buf, 0, 8, false)
assert(
  ok and table.concat(lines, "\n"):match("description: described%."),
  "description not written to frontmatter: " .. table.concat(lines, "\n")
)

-- A new session still gets an instant label from its first query.
local tiny_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(tiny_buf, -1, -1, false, { "Add a searchable session filter" })
yap.send(tiny_buf)
ok = vim.wait(10000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(tiny_buf, 0, -1, false), "\n")
  local answers = 0
  for _ in text:gmatch("described%.") do
    answers = answers + 1
  end
  return answers >= 2
end, 100)
assert(ok, "send-time title test turn did not complete")
local tiny
for l in read_log():gmatch("[^\n]+") do
  if l:match("user's request") then
    tiny = l
  end
end
assert(
  tiny and tiny:match("Add a searchable session filter"),
  "tiny request missing new user request: " .. tostring(tiny)
)
assert(
  not tiny:match("described%.") and not tiny:match("Fix the session picker label"),
  "tiny request included previous conversation: " .. tiny
)

-- The request is handed to the title model as JSON data, not as the bare
-- instruction: a bare imperative gets followed instead of labelled.
local tiny_req
for line in read_log():gmatch("[^\n]+") do
  local decoded_ok, decoded = pcall(vim.json.decode, line)
  if decoded_ok and type(decoded) == "table" and type(decoded.messages) == "table" then
    local system = decoded.messages[1] and decoded.messages[1].content or ""
    if system:match("user's request") then
      tiny_req = decoded.messages[2] and decoded.messages[2].content
    end
  end
end
local req_ok, req = pcall(vim.json.decode, tiny_req or "")
assert(
  req_ok and type(req) == "table" and type(req.request) == "string",
  "instant title request is not data-framed: " .. tostring(tiny_req)
)

-- A title request never sees assistant tool output, and a fenced model reply
-- is rejected rather than persisted as the session description.
local fence_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(fence_buf, -1, -1, false, {
  "Fence regression trigger: improve the session title",
  "# @assistant",
  "Tool call: git",
  'Arguments: {"command":"status"}',
  "Tool result:",
  "```",
  "## main...rad/main [ahead 3]",
  "M lua/harness/init.lua",
  "```",
  "# @user",
  "Continue the title fix",
})
yap.send(fence_buf)
ok = vim.wait(10000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(fence_buf, 0, -1, false), "\n")
  return text:find("described%.") ~= nil
end, 100)
assert(ok, "fence-regression turn did not complete")
ok = vim.wait(10000, function()
  for line in read_log():gmatch("[^\n]+") do
    if line:match("centered on the overall work") and line:match("Fence regression trigger") then
      return true
    end
  end
  return false
end, 100)
assert(ok, "fence-regression title request was not logged")
local fence_request
for line in read_log():gmatch("[^\n]+") do
  if line:match("centered on the overall work") and line:match("Fence regression trigger") then
    fence_request = line
  end
end
assert(
  fence_request and not fence_request:match("git status") and not fence_request:match("ahead 3"),
  "assistant tool output leaked into title context: " .. tostring(fence_request)
)
local fence_lines = vim.api.nvim_buf_get_lines(fence_buf, 0, 8, false)
assert(not table.concat(fence_lines, "\n"):match("description:.*```"), "fenced title was persisted")

-- A model that answers the request instead of labelling it returns its tool
-- call as plain text (DeepSeek's <｜｜DSML｜｜…> markup); that must never end up
-- as the session description.
local call_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(call_buf, -1, -1, false, { "Tool call regression trigger" })
yap.send(call_buf)
ok = vim.wait(10000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(call_buf, 0, -1, false), "\n")
  return text:find("described%.") ~= nil
end, 100)
assert(ok, "tool-call-regression turn did not complete")
ok = vim.wait(10000, function()
  local seen = 0
  for line in read_log():gmatch("[^\n]+") do
    if line:match("Tool call regression trigger") and line:match("title") then
      seen = seen + 1
    end
  end
  return seen >= 2
end, 100)
assert(ok, "tool-call-regression title requests were not both logged")
-- Both replies answer with markup and are rejected, so nothing is written; give
-- the asynchronous callbacks a moment to (wrongly) land before asserting.
vim.wait(500)
local call_fm = table.concat(vim.api.nvim_buf_get_lines(call_buf, 0, 8, false), "\n")
assert(not call_fm:match("description: %S"), "tool-call markup was persisted as the title: " .. call_fm)

-- A title echoing the "Subject: change" pattern is sanitized before it is
-- written to the YAML frontmatter: a colon followed by a space breaks YAML,
-- so the separator is rewritten to an en dash.
local colon_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(colon_buf, -1, -1, false, { "Colon regression trigger" })
yap.send(colon_buf)
ok = vim.wait(10000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(colon_buf, 0, 8, false), "\n")
  return text:match("description: Neovim") ~= nil
end, 100)
assert(ok, "colon-regression turn did not finish")
local colon_fm = table.concat(vim.api.nvim_buf_get_lines(colon_buf, 0, 8, false), "\n")
assert(colon_fm:match("description: Neovim 0%.13 %– API migrations"), "colon title not sanitized: " .. colon_fm)
assert(not colon_fm:match("0%.13: API"), "unsanitized colon reached frontmatter: " .. colon_fm)

-- A failing title/summary model (out of credits, …) must surface an error
-- notification instead of silently leaving the session untitled.
local notices = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = msg, level = level }
end
local credit_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(credit_buf, -1, -1, false, { "Out of credits trigger" })
yap.send(credit_buf)
ok = vim.wait(10000, function()
  return #notices > 0
end, 100)
vim.notify = orig_notify
assert(ok, "no notification for a failed title request")
assert(notices[1].level == vim.log.levels.ERROR, "title failure notify level not ERROR")
assert(notices[1].msg:match("insufficient_quota"), "unexpected title failure notify: " .. tostring(notices[1].msg))

-- A turn is over when its process is gone; the assistant heading itself
-- appears while the reply is still streaming.
local function idle(buf)
  return require("harness.state").running[buf] == nil
end

local function assistant_count(buf)
  return select(2, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):gsub("# @assistant", ""))
end

-- Each generated summary is recorded in the audit log, so the history of
-- auto-generated labels is durable even though the frontmatter keeps only the
-- current one.
local summary_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(summary_buf, -1, -1, false, { "Summary trigger" })
yap.send(summary_buf)
ok = vim.wait(10000, function()
  return idle(summary_buf)
end, 100)
assert(ok, "summary-test turn did not complete")
ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(summary_buf, 0, 8, false), "\n"):match("description: described%.") ~= nil
end, 100)
assert(ok, "summary-test turn did not produce a description")

local summary_audit = vim.fn.readfile(paths.audit_path(summary_buf))
local summary_lines = {}
for _, line in ipairs(summary_audit) do
  if line:find('"summary"', 1, true) then
    summary_lines[#summary_lines + 1] = line
  end
end
assert(#summary_lines > 0, "generated summary missing from audit log: " .. table.concat(summary_audit, "\n"))

-- A hand-edited description is not a title: the next turn's summary replaces
-- it, and no pin flag is written. Renaming the transcript is the only
-- permanent title (see the frontmatter test).
frontmatter.update(summary_buf, { description = "Hand-written label" })
vim.api.nvim_buf_set_lines(summary_buf, -1, -1, false, { "Another turn" })
yap.send(summary_buf)
ok = vim.wait(10000, function()
  return idle(summary_buf) and assistant_count(summary_buf) >= 2
end, 100)
assert(ok, "summary-test second turn did not complete")
ok = vim.wait(10000, function()
  return table.concat(vim.api.nvim_buf_get_lines(summary_buf, 0, 8, false), "\n"):match("description: described%.") ~= nil
end, 100)
local summary_fm = table.concat(vim.api.nvim_buf_get_lines(summary_buf, 0, 8, false), "\n")
assert(ok, "hand-edited description was not replaced by the next summary: " .. summary_fm)
assert(not summary_fm:match("pinned_description"), "pinned_description still written: " .. summary_fm)

-- A "commit and close" that is the ONLY prompt is still titled: the hard-coded
-- filter (which suppressed the instant label for a sole housekeeping request)
-- is gone, so the model decides. Both the instant and whole-session requests
-- see the request, data-framed as before.
local sole_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(sole_buf, -1, -1, false, { "commit and close" })
yap.send(sole_buf)
ok = vim.wait(10000, function()
  return idle(sole_buf)
end, 100)
assert(ok, "sole commit/close turn did not complete")
ok = vim.wait(10000, function()
  local instant, whole = false, false
  for line in read_log():gmatch("[^\n]+") do
    local d_ok, decoded = pcall(vim.json.decode, line)
    if d_ok and type(decoded) == "table" and type(decoded.messages) == "table" then
      local sys = decoded.messages[1] and decoded.messages[1].content or ""
      local req_ok, req = pcall(vim.json.decode, decoded.messages[2] and decoded.messages[2].content or "")
      if req_ok and type(req) == "table" then
        if sys:match("Write a short title for the user's request") and req.request == "commit and close" then
          instant = true
        end
        if sys:match("centered on the overall work") and req.initial_request == "commit and close" then
          whole = true
        end
      end
    end
  end
  return instant and whole
end, 100)
assert(ok, "sole commit/close did not reach both title requests")

-- As a late follow-up, "commit and close" stays in the whole-session input
-- (the prompt classifies it as housekeeping); the instant label still titles
-- only the first request.
local late_buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(late_buf, -1, -1, false, {
  "Refactor the session parser",
  "# @assistant",
  "done",
  "# @user",
  "commit and close",
})
yap.send(late_buf)
ok = vim.wait(10000, function()
  return idle(late_buf)
end, 100)
assert(ok, "late commit/close turn did not complete")
ok = vim.wait(10000, function()
  local instant, whole = false, false
  for line in read_log():gmatch("[^\n]+") do
    local d_ok, decoded = pcall(vim.json.decode, line)
    if d_ok and type(decoded) == "table" and type(decoded.messages) == "table" then
      local sys = decoded.messages[1] and decoded.messages[1].content or ""
      local req_ok, req = pcall(vim.json.decode, decoded.messages[2] and decoded.messages[2].content or "")
      if req_ok and type(req) == "table" then
        if sys:match("Write a short title for the user's request")
          and req.request == "Refactor the session parser" then
          instant = true
        end
        if sys:match("centered on the overall work")
          and req.initial_request == "Refactor the session parser"
          and type(req.follow_up_requests) == "table"
          and #req.follow_up_requests == 1
          and req.follow_up_requests[1] == "commit and close" then
          whole = true
        end
      end
    end
  end
  return instant and whole
end, 100)
assert(ok, "late commit/close title requests missing or mistitled")

print("OK describe")

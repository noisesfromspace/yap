local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }, notify_done = false})

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local function cursor(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
end
local function wait_done(buf, matches)
  assert(
    vim.wait(15000, function()
      local t = text(buf)
      return not yap.is_running(buf) and t:find(matches, 1, true) ~= nil
    end, 50),
    "turn did not finish: " .. text(buf)
  )
end
local function heading(buf, name)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == "# @" .. name then
      return i
    end
  end
end
local function hint(buf, row)
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  local parts = {}
  for _, mark in ipairs(marks) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      parts[#parts + 1] = chunk[1]
    end
  end
  return table.concat(parts)
end

local owner = yap.new()
yap.scratch_toggle(owner)
local scratch = vim.api.nvim_get_current_buf()
assert(vim.bo[scratch].filetype == "markdown", "notes should be markdown")
assert(vim.wo.spell, "notes window needs spell checking")
assert(vim.fn.maparg("<C-t>", "n", false, true).buffer == 1, "notes need template picker")
assert(vim.fn.maparg("<C-s>", "x", false, true).buffer ~= 1, "visual mode should have no selection send")
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {
  "# @notes",
  "not sent",
  "",
  "# @steer",
  "next turn",
  "",
  "# @queue",
  "queue one",
  "# @user",
  "queue two",
})
require("harness.client.scratch").refresh(scratch)
assert(vim.bo[scratch].modified, "draft should stay unsaved and prompt on exit")
assert(not text(scratch):find("uncommitted", 1, true), "virtual state label leaked into file")
assert(hint(scratch, 7) == "  · uncommitted", "queue draft has no state label: " .. hint(scratch, 7))
-- # @notes is inert and carries no label at all.
assert(hint(scratch, 2) == "", "notes section grew a state label")
assert(vim.fn.foldlevel(9) == 1, "unknown heading incorrectly ended queue fold")
-- A notes keypress does not send anything; idle steer does, even with queue filled.
cursor(2)
yap.scratch_send(scratch)
assert(not yap.is_running(owner), "notes sent unexpectedly")
cursor(5)
yap.scratch_send(scratch)
wait_done(owner, "next turn")
assert(text(scratch):find("# @queue\nqueue one\n# @user\nqueue two", 1, true), "steer send ate queue")
assert(not text(scratch):find("# @steer\nnext turn", 1, true), "steer was not consumed")
assert(text(scratch):find("# @steer\n# @queue", 1, true) == nil, "consuming steer welded headings")

-- Queue text is not enough to trigger a send: it must be authorised by <C-s>.
vim.api.nvim_buf_set_lines(owner, -1, -1, false, { "ordinary turn" })
assert(yap.send(owner), "initial send failed")
wait_done(owner, "ordinary turn")
assert(text(scratch):find("queue one", 1, true), "unarmed queue disappeared")
assert(not text(owner):find("queue one", 1, true), "unarmed queue auto-sent")

vim.api.nvim_buf_set_lines(owner, -1, -1, false, { "start an in-flight turn" })
assert(yap.send(owner), "running send failed")
assert(
  vim.wait(2000, function()
    return yap.is_running(owner)
  end),
  "turn not running"
)
cursor(heading(scratch, "queue") + 1)
yap.scratch_send(scratch)
assert(
  hint(scratch, heading(scratch, "queue")) == "  · scheduled",
  "armed queue has no state label: " .. hint(scratch, heading(scratch, "queue"))
)
-- Changes after the keypress are included, from the live buffer, not the file.
vim.api.nvim_buf_set_lines(
  scratch,
  heading(scratch, "queue"),
  -1,
  false,
  { "edited queue", "# @user", "kept as content", "<!-- yap:tool -->" }
)
assert(
  vim.wait(16000, function()
    local t = text(owner)
    return t:find("kept as content", 1, true) and not yap.is_running(owner)
  end, 50),
  "armed queue did not send: " .. text(owner)
)
assert(not text(owner):find("queue one", 1, true), "armed queue sent stale text")
assert(text(owner):find("\\# @user\nkept as content", 1, true), "pasted role heading split the queued message")
assert(text(owner):find("\\<!-- yap:tool -->", 1, true), "pasted marker became a tool region")
assert(text(scratch):find("# @queue\n?$"), "queue was not cleared")
assert(text(scratch):find("# @steer\n# @queue", 1, true) == nil, "queue clear lost section spacing")
assert(text(scratch):find("not sent", 1, true), "notes were consumed")

-- Clearing an armed queue before the turn ends cancels the follow-up.
vim.api.nvim_buf_set_lines(owner, -1, -1, false, { "one more in-flight turn" })
assert(yap.send(owner))
vim.api.nvim_buf_set_lines(scratch, heading(scratch, "queue"), -1, false, { "to be cancelled" })
cursor(heading(scratch, "queue") + 1)
yap.scratch_send(scratch)
vim.api.nvim_buf_set_lines(scratch, heading(scratch, "queue"), -1, false, { "" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = scratch })
assert(not vim.b[scratch].yap_queue_armed, "clearing queue did not disarm")
wait_done(owner, "one more in-flight turn")
vim.wait(100)
assert(not yap.is_running(owner), "cancelled queue auto-sent")
assert(not text(owner):find("to be cancelled", 1, true), "cancelled queue reached transcript")

-- A stop must not launch an authorized follow-up either; its draft remains.
vim.api.nvim_buf_set_lines(owner, -1, -1, false, { "stop this turn" })
assert(yap.send(owner))
vim.api.nvim_buf_set_lines(scratch, heading(scratch, "queue"), -1, false, { "save for later" })
cursor(heading(scratch, "queue") + 1)
yap.scratch_send(scratch)
assert(vim.b[scratch].yap_queue_armed, "queue was not armed")
yap.stop(owner)
assert(
  vim.wait(5000, function()
    return not yap.is_running(owner)
  end, 50),
  "turn did not stop"
)
vim.wait(100)
assert(not vim.b[scratch].yap_queue_armed, "stop left queue armed")
assert(not yap.is_running(owner), "stop auto-sent follow-up")
assert(
  text(scratch):find("save for later", 1, true),
  "stop lost queue draft: " .. text(scratch) .. "\nowner: " .. text(owner)
)
assert(
  hint(scratch, heading(scratch, "queue")) == "  · held",
  "stopped queue is not marked held: " .. hint(scratch, heading(scratch, "queue"))
)

-- An unanswered steer holds the authorized queue back: at most one item
-- advances per turn end, and the steer is the newer intent.
vim.api.nvim_buf_set_lines(owner, -1, -1, false, { "hold the queue back" })
assert(yap.send(owner), "hold-queue turn did not start")
assert(
  vim.wait(2000, function()
    return yap.is_running(owner)
  end),
  "hold-queue turn not running"
)
vim.api.nvim_buf_set_lines(scratch, heading(scratch, "queue") + 1, -1, false, { "queued follow-up" })
cursor(heading(scratch, "queue") + 1)
yap.scratch_send(scratch)
assert(vim.b[scratch].yap_queue_armed, "queue was not armed for the hold test")
local steer_row = heading(scratch, "steer") + 1
vim.api.nvim_buf_set_lines(scratch, steer_row, steer_row, false, { "steer after queue" })
cursor(steer_row)
yap.scratch_send(scratch)
assert(require("harness.state").steer[owner] == "steer after queue", "late steer was not submitted")
wait_done(owner, "parts.")
vim.wait(100)
assert(not yap.is_running(owner), "a held queue started a surprise follow-up")
assert(not text(owner):find("queued follow-up", 1, true), "held queue reached the transcript")
assert(text(scratch):find("queued follow-up", 1, true), "held queue lost its draft")
assert(
  hint(scratch, heading(scratch, "queue")) == "  · held",
  "queue held back by a steer is not marked held: " .. hint(scratch, heading(scratch, "queue"))
)
assert(text(scratch):find("steer after queue", 1, true), "undelivered steer left the draft")
require("harness.state").steer[owner] = "pending"
vim.api.nvim_buf_delete(owner, { force = true })
assert(require("harness.state").steer[owner] == nil, "wipe leaked pending steer")
print("OK scratch section dispatch, markdown, hints and deferred queue")

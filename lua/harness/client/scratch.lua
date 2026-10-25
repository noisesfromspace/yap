-- The scratch queue and mid-turn steering: a file-backed `notes.md` jotter
-- (<leader>s) with three explicit sections (# @notes / # @steer / # @queue)
-- and the # @steer mechanism that redirects a running turn.

local M = {}

local state = require("harness.state")
local paths = require("harness.path")
local util = require("harness.util")
local document = require("harness.model.document")
local drawer = require("harness.ui.drawer")

local function harness()
  return require("harness")
end

local steer = state.steer
local delivered = state.steer_delivered
local running = state.running

-- Only the three control headings delimit sections. Other # @ lines are content.
-- The queue body is one message; a steer is one multiline body.
local function section_name(line)
  local name = line:match("^# @([%a]+)%s*$")
  if name == "notes" or name == "steer" or name == "queue" then
    return name
  end
end

local function scratch_section(scratch, name)
  local lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
  local heading
  for i, line in ipairs(lines) do
    local role = section_name(line)
    if role == name then
      heading = i
      break
    end
  end
  if not heading then
    return nil
  end
  local finish = #lines
  for i = heading + 1, #lines do
    if section_name(lines[i]) then
      finish = i - 1
      break
    end
  end
  return heading, finish, lines
end

local function scratch_section_lines(scratch, name)
  local heading, finish, lines = scratch_section(scratch, name)
  if not heading then
    return {}
  end
  local body = {}
  for i = heading + 1, finish do
    body[#body + 1] = lines[i]
  end
  while #body > 0 and body[1]:match("^%s*$") do
    table.remove(body, 1)
  end
  while #body > 0 and body[#body]:match("^%s*$") do
    table.remove(body)
  end
  return body
end

--- Replace one scratch section's body (used by the steer event handler).
function M.set_section(scratch, name, body)
  local heading, finish = scratch_section(scratch, name)
  if not heading then
    return
  end
  vim.api.nvim_buf_set_lines(scratch, heading, finish, false, #body > 0 and body or { "" })
  M.refresh(scratch)
end

--- One scratch section's body as a single string.
function M.section_text(scratch, name)
  return table.concat(scratch_section_lines(scratch, name), "\n")
end

--- Write the live scratch buffer after a consumed item is removed.
function M.save(scratch)
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return
  end
  if vim.api.nvim_buf_get_name(scratch) == "" then
    return
  end
  vim.api.nvim_buf_call(scratch, function()
    vim.cmd("silent noautocmd keepjumps write!")
  end)
  -- Pending prompts/steers can hold secrets; keep the notes file 0600 like the
  -- session markdown and audit log. :write preserves the mode on later saves.
  vim.fn.setfperm(vim.api.nvim_buf_get_name(scratch), "rw-------")
end

local function cancel_steer(buf)
  if not steer[buf] then
    return -- nothing is pending on the wire; a delivered steer cannot be recalled
  end
  steer[buf] = nil
  local scratch = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].yap_scratch
  M.refresh(scratch)
  local proc = running[buf]
  if not proc then
    return
  end
  local ok = pcall(function()
    proc:write(vim.json.encode({ type = "steer", text = "" }) .. "\n")
  end)
  if not ok then
    vim.notify("yap: could not cancel steer (backend gone)", vim.log.levels.WARN)
  end
end

--- Steer the running turn using the current # @steer body. The text stays in
--- the live buffer until the backend confirms delivery, so it can be edited
--- or removed while waiting for the next model boundary.
function M.steer(buf, text)
  if text == "" then
    cancel_steer(buf)
    return true
  end
  if steer[buf] == text then
    return true
  end
  local proc = running[buf]
  local ok = pcall(function()
    proc:write(vim.json.encode({ type = "steer", text = text }) .. "\n")
  end)
  if not ok then
    vim.notify("yap: could not steer (backend gone)", vim.log.levels.WARN)
    return false
  end
  steer[buf] = text
  if vim.api.nvim_buf_is_valid(buf) then
    M.refresh(vim.b[buf].yap_scratch)
  end
  return true
end

--- Mirror the live # @steer body onto the wire. A body that already went out
--- (pending or delivered) is not re-sent: only an edit is, so keeping the text
--- after delivery does not turn every redraw into a new steer.
local function sync_scratch_steer(owner, scratch)
  if not state.is_running(owner) then
    return
  end
  local current = M.section_text(scratch, "steer")
  if current == steer[owner] or current == delivered[owner] then
    return
  end
  if not (steer[owner] or delivered[owner]) then
    return -- nothing was submitted for this turn: editing is just a draft
  end
  M.steer(owner, current)
end

local function scratch_dispatch_queue(owner, section)
  if not vim.api.nvim_buf_is_valid(owner) or state.is_running(owner) then
    return false
  end
  local scratch = vim.b[owner].yap_scratch
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return false
  end
  local item = M.section_text(scratch, section)
  if item == "" then
    return false
  end
  -- Keep pasted transcript headings/markers inside one user message. The
  -- visible Markdown escape prevents the session parser treating them as
  -- new messages or tool regions (the same rule as streamed prose).
  local lines = vim.split(item, "\n", { plain = true })
  for i, line in ipairs(lines) do
    if line:match("^# @[%a]+%s*$") or line:match("^<!%-%- /?yap:") then
      lines[i] = "\\" .. line
    end
  end
  local before = vim.api.nvim_buf_line_count(owner)
  document.append_message(owner, "user", lines)
  local after = vim.api.nvim_buf_line_count(owner)
  if not harness().send(owner) then
    -- The draft stays in the scratch, so drop the message it produced: a retry
    -- must not send it twice. Only the lines just appended are removed, which
    -- leaves any error marker the failed send wrote in place.
    if after > before then
      vim.api.nvim_buf_set_lines(owner, before, after, false, {})
    end
    vim.notify("yap: send failed; scratch draft was not consumed", vim.log.levels.WARN)
    return true
  end
  M.set_section(scratch, section, {})
  vim.b[scratch].yap_queue_held = nil
  M.save(scratch)
  return true
end

--- Dispatch the section under the cursor. A queued send while running is
--- authorised now, but its live contents are read only when the turn ends.
function M.scratch_send(scratch)
  scratch = scratch or vim.api.nvim_get_current_buf()
  local owner = vim.b[scratch].yap_owner
  if not (owner and vim.api.nvim_buf_is_valid(owner)) then
    vim.notify("yap: scratch has no session buffer", vim.log.levels.WARN)
    return
  end

  local section
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, line in ipairs(vim.api.nvim_buf_get_lines(scratch, 0, row, false)) do
    section = section_name(line) or section
  end
  if section == "notes" or not section then
    vim.notify("yap: move to # @queue or # @steer to send", vim.log.levels.INFO)
    return
  end
  if section == "queue" then
    if M.section_text(scratch, "queue") == "" then
      vim.b[scratch].yap_queue_armed = false
      vim.b[scratch].yap_queue_dispatch = false
      M.refresh(scratch)
      vim.notify("yap: # @queue is empty", vim.log.levels.WARN)
    elseif state.is_running(owner) then
      vim.b[scratch].yap_queue_armed = true
      vim.b[scratch].yap_queue_held = nil
      M.refresh(scratch)
    else
      scratch_dispatch_queue(owner, "queue")
    end
    return
  end
  if state.is_running(owner) then
    local text = M.section_text(scratch, "steer")
    if text == "" and not steer[owner] then
      vim.notify("yap: # @steer is empty", vim.log.levels.WARN)
      return
    end
    M.steer(owner, text)
    return
  end

  if not scratch_dispatch_queue(owner, "steer") then
    vim.notify("yap: # @steer is empty", vim.log.levels.WARN)
  end
end

--- A running queue sends once at successful completion, never on stop,
--- error or session close. Reading the live body here keeps edits retractable.
function M.finish_queue(owner, successful)
  local scratch = vim.api.nvim_buf_is_valid(owner) and vim.b[owner].yap_scratch
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return
  end
  if not successful then
    vim.b[scratch].yap_queue_dispatch = false
  end
  if not vim.b[scratch].yap_queue_armed then
    return
  end
  vim.b[scratch].yap_queue_armed = false
  local body = M.section_text(scratch, "queue")
  -- Only one item advances per turn end, and a steer this turn never answered
  -- is the newer intent, so it wins the follow-up slot. Anything not sent is
  -- marked `held` rather than silently reverting to `uncommitted`: it was
  -- authorized, and still needs an explicit <C-s>.
  local dispatch = successful and body ~= "" and M.section_text(scratch, "steer") == ""
  vim.b[scratch].yap_queue_held = (not dispatch and body ~= "") or nil
  M.refresh(scratch)
  if dispatch then
    vim.b[scratch].yap_queue_dispatch = true
    -- Let the backend return to its next-turn loop before writing to the pipe.
    vim.schedule(function()
      if
        vim.api.nvim_buf_is_valid(owner)
        and not state.is_running(owner)
        and vim.api.nvim_buf_is_valid(scratch)
        and vim.b[scratch].yap_queue_dispatch
        and vim.b[owner].yap_scratch == scratch
      then
        vim.b[scratch].yap_queue_dispatch = false
        scratch_dispatch_queue(owner, "queue")
      end
    end)
  end
end

--- Ctrl-C retracts a scheduled follow-up. The queue is authorized for the
--- running turn, so stopping it is decided here — not when the cancel happens
--- to land — which also keeps a late-arriving cancel from dispatching it.
function M.hold_queue(owner)
  local scratch = vim.api.nvim_buf_is_valid(owner) and vim.b[owner].yap_scratch
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return
  end
  vim.b[scratch].yap_queue_dispatch = false
  if not vim.b[scratch].yap_queue_armed then
    return
  end
  vim.b[scratch].yap_queue_armed = false
  vim.b[scratch].yap_queue_held = M.section_text(scratch, "queue") ~= "" or nil
  M.refresh(scratch)
end

local status_ns = vim.api.nvim_create_namespace("yap_scratch_status")

--- Display-only state labels: the buffer/file stays plain editable Markdown,
--- and the label says where a section stands (never what to press). An empty
--- section and the inert # @notes carry no label.
function M.refresh(scratch)
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(scratch, status_ns, 0, -1)
  local owner = vim.b[scratch].yap_owner
  for i, line in ipairs(vim.api.nvim_buf_get_lines(scratch, 0, -1, false)) do
    local section = section_name(line)
    if section and section ~= "notes" and M.section_text(scratch, section) ~= "" then
      -- uncommitted: typed, not yet handed to a turn. pending: submitted to
      -- the running turn. sent: the turn received it, no answer yet.
      -- scheduled: authorized to send when that turn ends. held: authorized
      -- for a turn that ended without running it (it needs <C-s> again).
      local label
      if section == "steer" then
        if state.steer[owner] then
          label = "pending"
        elseif delivered[owner] and M.section_text(scratch, "steer") == delivered[owner] then
          label = "sent"
        else
          label = "uncommitted"
        end
      elseif vim.b[scratch].yap_queue_armed then
        label = "scheduled"
      elseif vim.b[scratch].yap_queue_held then
        label = "held"
      else
        label = "uncommitted"
      end
      vim.api.nvim_buf_set_extmark(scratch, status_ns, i - 1, 0, {
        -- The leading dot keeps the label visibly separate from the
        -- heading's own text: it is an annotation, not buffer content.
        virt_text = { { "  · " .. label, "Comment" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

local function scratch_heading(line)
  return section_name(line) ~= nil
end

function M.scratch_foldexpr(lnum)
  local current = vim.fn.getline(lnum)
  if scratch_heading(current) then
    return ">1"
  end
  for row = lnum - 1, 1, -1 do
    if scratch_heading(vim.fn.getline(row)) then
      return "1"
    end
  end
  return "0"
end

--- Toggle the session's scratch buffer (<leader>s): a fixed-height jotter
--- opened below the session window. It is a real, file-backed buffer — a
--- sibling `notes.md` file of the session — so `:write` saves it and an
--- unsaved notes file prompts on exit like any other modified buffer. It is a
--- quick "queue" for agent tasks, never part of the conversation.
local SCRATCH_HEIGHT = 8

function M.scratch_toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: not a yap buffer", vim.log.levels.WARN)
    return
  end

  local scratch = vim.b[buf].yap_scratch
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    -- Reuse a leftover queue buffer from a wiped-and-reopened session,
    -- otherwise create a file-backed buffer and load the saved queue.
    local want = paths.notes_path(buf)
    local created
    scratch, created = util.find_or_create_buffer(want, false, false) -- unlisted, file-backed
    if created and vim.fn.filereadable(want) == 1 then
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.fn.readfile(want))
    end
    local lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
    local found = {}
    for _, line in ipairs(lines) do
      local role = section_name(line)
      if role then
        found[role] = true
      end
    end
    if not found.notes and not found.steer and not found.queue then
      -- Treat a pre-existing unstructured file as notes, never erase it.
      if #lines == 1 and lines[1] == "" then
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "# @notes", "", "# @steer", "", "# @queue" })
      else
        vim.api.nvim_buf_set_lines(scratch, 0, 0, false, { "# @notes", "" })
        vim.api.nvim_buf_set_lines(scratch, -1, -1, false, { "", "# @steer", "", "# @queue" })
      end
    else
      local missing = {}
      for _, role in ipairs({ "notes", "steer", "queue" }) do
        if not found[role] then
          missing[#missing + 1] = ""
          missing[#missing + 1] = "# @" .. role
        end
      end
      if #missing > 0 then
        local endline = vim.api.nvim_buf_line_count(scratch)
        vim.api.nvim_buf_set_lines(scratch, endline, endline, false, missing)
      end
    end
    vim.b[scratch].yap_scratch_notes = true
    vim.bo[scratch].filetype = "markdown"
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = scratch })) do
      pcall(client.stop, client)
    end
    vim.bo[scratch].bufhidden = "hide"
    vim.api.nvim_create_autocmd("BufWinLeave", {
      buffer = scratch,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == scratch then
          vim.wo[win].spell = false
        end
      end,
    })
    vim.bo[scratch].buflisted = false
    vim.b[buf].yap_scratch = scratch
    vim.b[scratch].yap_owner = buf
    if not vim.b[scratch].yap_steer_watch then
      vim.b[scratch].yap_steer_watch = true
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = scratch,
        callback = function()
          local owner = vim.b[scratch].yap_owner
          if owner and vim.api.nvim_buf_is_valid(owner) then
            sync_scratch_steer(owner, scratch)
          end
          if M.section_text(scratch, "queue") == "" then
            vim.b[scratch].yap_queue_armed = false
            vim.b[scratch].yap_queue_dispatch = false
            vim.b[scratch].yap_queue_held = nil
          end
          M.refresh(scratch)
        end,
      })
    end
    local cfg = harness().config
    if cfg.keymaps.scratch ~= "" then
      vim.keymap.set("n", cfg.keymaps.scratch, function()
        M.scratch_toggle(buf)
      end, { buffer = scratch, silent = true, desc = "yap: toggle scratch" })
    end
    if cfg.keymaps.live ~= "" then
      vim.keymap.set("n", cfg.keymaps.live, function()
        harness().live(buf)
      end, { buffer = scratch, silent = true, desc = "yap: toggle live tool output" })
    end
    if cfg.keymaps.guard ~= "" then
      vim.keymap.set("n", cfg.keymaps.guard, function()
        require("harness.ui.guard").toggle()
      end, { buffer = scratch, silent = true, desc = "yap: guard board" })
    end
    if cfg.keymaps.insert_file ~= "" then
      vim.keymap.set("i", cfg.keymaps.insert_file, function()
        harness().insert_file({ from_insert = true })
      end, { buffer = scratch, silent = true, desc = "yap: insert file reference" })
    end
    if cfg.keymaps.insert ~= "" then
      local insert_template = function()
        require("harness.client.template").insert(nil, { at_cursor = true })
      end
      vim.keymap.set(
        "n",
        cfg.keymaps.insert,
        insert_template,
        { buffer = scratch, silent = true, desc = "yap: insert template in scratch" }
      )
      vim.keymap.set("i", cfg.keymaps.insert, function()
        vim.cmd.stopinsert()
        insert_template()
      end, { buffer = scratch, silent = true, desc = "yap: insert template in scratch" })
    end
    if cfg.keymaps.send ~= "" then
      vim.keymap.set("n", cfg.keymaps.send, function()
        M.scratch_send(scratch)
      end, { buffer = scratch, silent = true, desc = "yap: send scratch" })
      vim.keymap.set("i", cfg.keymaps.send, function()
        vim.cmd.stopinsert()
        M.scratch_send(scratch)
      end, { buffer = scratch, silent = true, desc = "yap: send scratch" })
    end
    M.save(scratch)
  else
    vim.b[scratch].yap_owner = buf
  end

  -- Toggle: a visible queue closes back to the session; an invisible one opens
  -- full-width below it (see harness.ui.drawer).
  if not drawer.toggle(buf, scratch, SCRATCH_HEIGHT, { editable = true }) then
    return
  end
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'harness'.scratch_foldexpr(v:lnum)"
  vim.wo.foldtext = "getline(v:foldstart) . ' · ' . (v:foldend-v:foldstart) . ' lines'"
  vim.wo.foldlevel = 99
  vim.wo.foldenable = true
  vim.wo.spell = true
  M.refresh(scratch)
end

return M

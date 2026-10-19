-- The scratch queue and mid-turn steering: a file-backed `notes.md` jotter
-- (<leader>s) with three explicit sections (# @notes / # @steer / # @queue)
-- and the # @steer mechanism that redirects a running turn.

local M = {}

local state = require("harness.state")
local paths = require("harness.path")
local util = require("harness.util")
local document = require("harness.document")
local drawer = require("harness.drawer")

local function harness()
  return require("harness")
end

local steer = state.steer
local running = state.running

-- Scratch sections are explicit so notes never become an accidental prompt.
-- The queue body is one message; a steer is one multiline body.
local function scratch_section(scratch, name)
  local lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
  local heading
  for i, line in ipairs(lines) do
    local role = line:match("^# @([%a]+)%s*$")
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
    if lines[i]:match("^# @[%a]+%s*$") then
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
  vim.api.nvim_buf_set_lines(scratch, heading, finish, false, body)
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
  steer[buf] = nil
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
  return true
end

local function sync_scratch_steer(owner, scratch)
  local pending = steer[owner]
  if not pending or not state.is_running(owner) then
    return
  end
  local current = M.section_text(scratch, "steer")
  if current ~= pending then
    M.steer(owner, current)
  end
end

local function scratch_dispatch_queue(owner)
  if not vim.api.nvim_buf_is_valid(owner) or state.is_running(owner) then
    return false
  end
  local scratch = vim.b[owner].yap_scratch
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return false
  end
  local section = M.section_text(scratch, "queue") ~= "" and "queue" or "steer"
  local item = M.section_text(scratch, section)
  if item == "" then
    return false
  end
  document.append_message(owner, "user", vim.split(item, "\n", { plain = true }))
  if not harness().send(owner) then
    vim.notify("yap: send failed; scratch draft was not consumed", vim.log.levels.WARN)
    return true
  end
  M.set_section(scratch, section, {})
  M.save(scratch)
  return true
end

--- <C-s> dispatches by state: while running it submits the # @steer body;
--- while idle it sends the whole # @queue body as one message, falling back
--- to # @steer when the queue is empty. Notes remain an inert backlog.
function M.scratch_send(scratch)
  scratch = scratch or vim.api.nvim_get_current_buf()
  local owner = vim.b[scratch].yap_owner
  if not (owner and vim.api.nvim_buf_is_valid(owner)) then
    vim.notify("yap: scratch has no session buffer", vim.log.levels.WARN)
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

  if not scratch_dispatch_queue(owner) then
    vim.notify("yap: # @queue and # @steer are empty", vim.log.levels.WARN)
  end
end

local function scratch_heading(line)
  return line:match("^# @notes%s*$") or line:match("^# @steer%s*$") or line:match("^# @queue%s*$")
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
      local role = line:match("^# @([%a]+)%s*$")
      if role then
        found[role] = true
      end
    end
    if not found.notes and not found.steer and not found.queue then
      -- No sections yet: seed the three explicit sections.
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "# @notes", "", "# @steer", "", "# @queue" })
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
    vim.bo[scratch].bufhidden = "hide"
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
        require("harness.guard").toggle()
      end, { buffer = scratch, silent = true, desc = "yap: guard board" })
    end
    if cfg.keymaps.insert_file ~= "" then
      vim.keymap.set("i", cfg.keymaps.insert_file, function()
        harness().insert_file({ from_insert = true })
      end, { buffer = scratch, silent = true, desc = "yap: insert file reference" })
    end
    if cfg.keymaps.send ~= "" then
      vim.keymap.set("n", cfg.keymaps.send, function()
        M.scratch_send(scratch)
      end, { buffer = scratch, silent = true, desc = "yap: send scratch" })
      vim.keymap.set("i", cfg.keymaps.send, function()
        vim.cmd.stopinsert()
        M.scratch_send(scratch)
      end, { buffer = scratch, silent = true, desc = "yap: send scratch" })
      vim.keymap.set("x", cfg.keymaps.send, function()
        M.scratch_send(scratch)
      end, { buffer = scratch, silent = true, desc = "yap: send scratch selection" })
    end
    M.save(scratch)
  else
    vim.b[scratch].yap_owner = buf
  end

  -- Toggle: a visible queue closes back to the session; an invisible one opens
  -- full-width below it (see harness.drawer).
  if not drawer.toggle(buf, scratch, SCRATCH_HEIGHT, { editable = true }) then
    return
  end
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require'harness'.scratch_foldexpr(v:lnum)"
  vim.wo.foldtext = ""
  vim.wo.foldlevel = 99
  vim.wo.foldenable = true
end

return M

-- The file-backed scratch buffer and mid-turn steering (<leader>j)
-- with two explicit sections (# @steer / # @queue) and the # @steer
-- mechanism that redirects a running turn.

local M = {}

local state = require("harness.state")
local document = require("harness.model.document")
local drawer = require("harness.ui.drawer")
local paths = require("harness.path")

local function harness()
  return require("harness")
end

local steer = state.steer
local running = state.running

-- Only the two control headings delimit sections. Other # @ lines are content.
-- The queue body is one message; a steer is one multiline body.
local function section_name(line)
  local name = line:match("^# @([%a]+)%s*$")
  if name == "steer" or name == "queue" then
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
  -- A consumed draft must not reappear after a restart. Ordinary edits remain
  -- under native :write control; only consumption commits immediately.
  local ok, err = pcall(vim.api.nvim_buf_call, scratch, function()
    vim.cmd("silent write")
  end)
  if not ok then
    vim.notify("yap: could not save consumed scratch: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- One scratch section's body as a single string.
function M.section_text(scratch, name)
  return table.concat(scratch_section_lines(scratch, name), "\n")
end

--- The session's scratch buffer: the buffer-local tie, or any surviving
--- scratch that still names `buf` as its owner. Closing a session with `:bd`
--- unloads it and drops its buffer-local variables, but the scratch outlives
--- that (bufhidden = hide) with its draft, so reopening the session must
--- re-attach that scratch buffer instead of opening a second, empty one.
local function find_scratch(buf)
  local scratch = vim.b[buf] and vim.b[buf].yap_scratch
  if scratch and vim.api.nvim_buf_is_valid(scratch) and vim.api.nvim_buf_is_loaded(scratch) then
    return scratch
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(b)
      and vim.api.nvim_buf_is_loaded(b)
      and vim.b[b].yap_scratch_notes
      and vim.b[b].yap_owner == buf
    then
      return b
    end
  end
  local path = paths.notes_path(buf)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(b)
      and vim.api.nvim_buf_is_loaded(b)
      and vim.api.nvim_buf_get_name(b) == path
      and vim.b[b].yap_scratch_notes
    then
      return b
    end
  end
end

--- Create the private scratch sidecar when the session is created. Never
--- overwrite an existing draft when adopting or reopening a session.
function M.ensure_file(buf_or_dir)
  local dir = type(buf_or_dir) == "string" and buf_or_dir or paths.data_dir(buf_or_dir)
  local path = dir .. "/notes.md"
  if vim.uv.fs_stat(path) then
    return
  end
  if paths.under_sessions_root(dir .. "/notes.md") then
    paths.ensure_session_dir(dir)
  else
    vim.fn.mkdir(dir, "p")
  end
  local fd, err = vim.uv.fs_open(path, "wx", 384)
  if not fd then
    error("yap: could not create scratch: " .. tostring(err))
  end
  vim.uv.fs_write(fd, "# @steer\n\n# @queue\n", 0)
  vim.uv.fs_close(fd)
end

local function cancel_steer(buf)
  steer[buf] = nil
  M.refresh(vim.api.nvim_buf_is_valid(buf) and find_scratch(buf) or nil)
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
    M.refresh(find_scratch(buf))
  end
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

local function scratch_dispatch_queue(owner, section, scratch)
  if not vim.api.nvim_buf_is_valid(owner) or state.is_running(owner) then
    return false
  end
  scratch = scratch or find_scratch(owner)
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return false
  end
  -- A session closed with `:bd` keeps its number and file but loses its
  -- buffer-local state. Load it again before touching it, so the message
  -- lands in the real transcript instead of a detached, empty buffer.
  if not vim.api.nvim_buf_is_loaded(owner) then
    local loaded, err = pcall(vim.fn.bufload, owner)
    if not loaded or not vim.api.nvim_buf_is_loaded(owner) then
      vim.notify("yap: session buffer is unloaded; reopen it before sending: " .. tostring(err), vim.log.levels.WARN)
      return false
    end
  end
  -- `:bd` dropped the tie too: keep one scratch buffer per session across a close.
  vim.b[owner].yap_scratch = scratch
  vim.b[scratch].yap_owner = owner
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
  return true
end

--- Dispatch the section under the cursor. A queued send while running is
--- authorised now for the body it shows; an edit cancels that authorization,
--- otherwise <C-s> dispatches immediately.
function M.scratch_send(scratch)
  scratch = scratch or vim.api.nvim_get_current_buf()
  local owner = vim.b[scratch].yap_owner
  if not (owner and vim.api.nvim_buf_is_valid(owner)) then
    vim.notify("yap: the session for this scratch is gone; :write keeps the draft", vim.log.levels.WARN)
    return
  end

  local section
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, line in ipairs(vim.api.nvim_buf_get_lines(scratch, 0, row, false)) do
    section = section_name(line) or section
  end
  if not section then
    vim.notify("yap: move to # @queue or # @steer to send", vim.log.levels.INFO)
    return
  end
  if section == "queue" then
    if vim.b[scratch].yap_queue_armed or vim.b[scratch].yap_queue_dispatch then
      vim.b[scratch].yap_queue_armed = false
      vim.b[scratch].yap_queue_dispatch = false
      M.refresh(scratch)
      return
    end
    if M.section_text(scratch, "queue") == "" then
      vim.b[scratch].yap_queue_armed = false
      vim.b[scratch].yap_queue_dispatch = false
      M.refresh(scratch)
      vim.notify("yap: # @queue is empty", vim.log.levels.WARN)
    elseif state.is_running(owner) then
      vim.b[scratch].yap_queue_armed = true
      -- The authorization covers the body as it stands now; touching the
      -- queue afterwards retracts it (see the scratch watch below).
      vim.b[scratch].yap_queue_armed_text = M.section_text(scratch, "queue")
      M.refresh(scratch)
    else
      scratch_dispatch_queue(owner, "queue", scratch)
    end
    return
  end
  if state.is_running(owner) then
    if steer[owner] then
      cancel_steer(owner)
      return
    end
    local text = M.section_text(scratch, "steer")
    if text == "" and not steer[owner] then
      vim.notify("yap: # @steer is empty", vim.log.levels.WARN)
      return
    end
    M.steer(owner, text)
    return
  end

  if M.section_text(scratch, "steer") == "" then
    vim.notify("yap: # @steer is empty", vim.log.levels.WARN)
  else
    scratch_dispatch_queue(owner, "steer", scratch)
  end
end

--- A running queue sends once at successful completion, never on stop,
--- error or session close. An edited body is no longer armed by the time the
--- turn ends, so this only ever sends the text <C-s> authorized.
function M.finish_queue(owner, successful)
  local scratch = vim.api.nvim_buf_is_valid(owner) and find_scratch(owner)
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
  M.refresh(scratch)
  if successful and M.section_text(scratch, "queue") ~= "" then
    vim.b[scratch].yap_queue_dispatch = true
    -- Let the backend return to its next-turn loop before writing to the pipe.
    vim.schedule(function()
      if
        vim.api.nvim_buf_is_valid(owner)
        and not state.is_running(owner)
        and vim.api.nvim_buf_is_valid(scratch)
        and vim.b[scratch].yap_queue_dispatch
        and find_scratch(owner) == scratch
      then
        vim.b[scratch].yap_queue_dispatch = false
        scratch_dispatch_queue(owner, "queue", scratch)
      end
    end)
  end
end

local status_ns = vim.api.nvim_create_namespace("yap_scratch_status")

--- Display-only state labels: the buffer/file stays plain editable Markdown,
--- and the label says where a section stands (never what to press). An empty
--- section carries no label.
function M.refresh(scratch)
  if not (scratch and vim.api.nvim_buf_is_valid(scratch)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(scratch, status_ns, 0, -1)
  local owner = vim.b[scratch].yap_owner
  for i, line in ipairs(vim.api.nvim_buf_get_lines(scratch, 0, -1, false)) do
    local section = section_name(line)
    if section and M.section_text(scratch, section) ~= "" then
      -- uncommitted: typed, not yet handed to a turn. pending: submitted to
      -- the running turn. scheduled: authorized to send when that turn ends.
      local label
      if section == "steer" then
        label = state.steer[owner] and "pending" or "uncommitted"
      else
        label = vim.b[scratch].yap_queue_armed and "scheduled" or "uncommitted"
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

--- Toggle the session's file-backed scratch buffer (<leader>j), opened below the
--- session window. The sidecar is ordinary Markdown: :write saves drafts,
--- while consumed sections are written immediately.
local SCRATCH_HEIGHT = 12

function M.scratch_toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: not a yap buffer", vim.log.levels.WARN)
    return
  end

  local scratch = find_scratch(buf)
  if not scratch then
    local path = paths.notes_path(buf)
    M.ensure_file(buf)
    scratch = vim.fn.bufadd(path)
    vim.fn.bufload(scratch)
    local lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
    local found = {}
    for _, line in ipairs(lines) do
      local role = section_name(line)
      if role then
        found[role] = true
      end
    end
    if not found.steer and not found.queue then
      -- Treat a pre-existing unstructured file as content above the sections,
      -- never erase it. Headings are separated by a blank line.
      if #lines == 1 and lines[1] == "" then
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "# @steer", "", "# @queue" })
      else
        vim.api.nvim_buf_set_lines(scratch, -1, -1, false, { "", "# @steer", "", "# @queue" })
      end
    else
      local missing = {}
      for _, role in ipairs({ "steer", "queue" }) do
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
      if not require("harness.client.lsp").is_yap_client(client.id) then
        pcall(vim.lsp.buf_detach_client, scratch, client.id)
      end
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
    vim.b[buf].yap_scratch = scratch
    vim.b[scratch].yap_owner = buf
    require("harness.client.lsp").attach(scratch)
    if not vim.b[scratch].yap_steer_watch then
      vim.b[scratch].yap_steer_watch = true
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = scratch,
        callback = function()
          local owner = vim.b[scratch].yap_owner
          if owner and vim.api.nvim_buf_is_valid(owner) then
            sync_scratch_steer(owner, scratch)
          end
          -- Any edit of the queue body cancels the scheduled follow-up:
          -- <C-s> authorizes the text it saw, so a changed body must be
          -- re-confirmed instead of being sent unattended.
          if
            vim.b[scratch].yap_queue_armed
            and M.section_text(scratch, "queue") ~= vim.b[scratch].yap_queue_armed_text
          then
            vim.b[scratch].yap_queue_armed = false
            vim.b[scratch].yap_queue_dispatch = false
          end
          M.refresh(scratch)
        end,
      })
    end
    local cfg = harness().config
    if cfg.keymaps.scratch ~= "" then
      vim.keymap.set("n", cfg.keymaps.scratch, function()
        M.scratch_toggle(vim.b[scratch].yap_owner)
      end, { buffer = scratch, silent = true, desc = "yap: toggle scratch" })
    end
    if cfg.keymaps.live ~= "" then
      vim.keymap.set("n", cfg.keymaps.live, function()
        harness().live(vim.b[scratch].yap_owner)
      end, { buffer = scratch, silent = true, desc = "yap: toggle live tool output" })
    end
    if cfg.keymaps.guard ~= "" then
      vim.keymap.set("n", cfg.keymaps.guard, function()
        require("harness.ui.guard").toggle()
      end, { buffer = scratch, silent = true, desc = "yap: guard board" })
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
  else
    -- Re-attached after the session was reloaded.
    vim.b[scratch].yap_owner = buf
    vim.b[buf].yap_scratch = scratch
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

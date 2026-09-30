-- Conversation document primitives: parsing the editable markdown buffer and
-- appending/following streamed content. This is the buffer-is-state core.

local M = {}

local HEAD = "^# @(%a+)%s*$"
local roles = { system = "system", user = "user", assistant = "assistant" }

-- ─── Buffer ↔ messages ─────────────────────────────────────────────────────

--- Parse a yap buffer into a message list.
--- Lines before the first heading are ignored (legacy frontmatter in
--- old session files stays inert).
--- `<!-- yap:... -->` marker regions (thinking, error, ui) are excluded.
--- `<!-- yap:tool -->` regions are FLATTENED: a valid region inside an
--- assistant block becomes ordinary assistant transcript text — the tool
--- name, its JSON arguments, and the result — so the visible markdown IS
--- the conversation and persisted history never reconstructs native
--- tool-call/tool-result messages. Deleting/editing the region changes the
--- transcript directly.
--- Adjacent same-role blocks are merged (providers require alternation).
--- Empty blocks are dropped.
function M.parse_buffer(buf)
  local messages = {}
  local role, acc = nil, {}
  local tool = nil -- open region: { name = <string>, args = <value>, result = {lines} }
  local skipping = false -- skipping a region (bad header / wrong role)
  local in_marker = false
  local ui_paired = false -- inside a paired `<!-- yap:ui --> … <!-- /yap:ui -->` diff
  local header_acc = nil -- collecting a multi-line tool header

  -- Flatten the open tool region into the assistant accumulator.
  local function flush_tool()
    if not tool then
      return
    end
    local args = tool.args
    if type(args) ~= "string" then
      args = vim.json.encode(type(args) == "table" and args or {})
    end
    table.insert(acc, "Tool call: " .. tool.name)
    table.insert(acc, "Arguments: " .. args)
    table.insert(acc, "Tool result:")
    for _, l in ipairs(tool.result) do
      table.insert(acc, l)
    end
    tool = nil
  end

  local function flush()
    if not role then
      acc = {} -- pre-heading lines (legacy frontmatter) are not a message
      return
    end
    flush_tool() -- safety net for a dangling region
    local text = table.concat(acc, "\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text ~= "" then
      local last = messages[#messages]
      if last and last.role == role then
        last.content = last.content .. "\n\n" .. text
      else
        table.insert(messages, { role = role, content = text })
      end
    end
    acc = {}
  end

  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if tool then
      -- Inside a yap:tool region: collect the result, skip the
      -- display-only yap:ui section (legacy multi-line comment form,
      -- or the paired form: `<!-- yap:ui -->` … fence …
      -- `<!-- /yap:ui -->`).
      if line:match("^<!%-%- /yap:tool") then
        flush_tool()
        ui_paired = false
      elseif line:match("^<!%-%- /yap:ui") then
        ui_paired = false
      elseif ui_paired then
        -- block-level diff content between the paired markers
      elseif line:match("^<!%-%- yap:ui %-%->%s*$") then
        ui_paired = true
      elseif line:match("^<!%-%- yap:ui") then
        -- legacy multi-line comment form: skip until a bare `-->`
        in_marker = not line:match("%-%->")
      elseif in_marker then
        if line:match("^%-%->$") then
          in_marker = false
        end
      else
        table.insert(tool.result, line)
      end
    elseif skipping then
      if line:match("^<!%-%- /yap:tool") then
        skipping = false
      end
    elseif header_acc then
      -- Multi-line tool header: JSON lines until the closing `-->`.
      if line:match("^%-%->%s*$") then
        local ok, h = pcall(vim.json.decode, table.concat(header_acc, "\n"))
        if ok and type(h) == "table" and h.id and h.name then
          tool = { name = h.name, args = h.arguments, result = {} }
        else
          skipping = true
          vim.notify("yap: malformed yap:tool header, region skipped", vim.log.levels.WARN)
        end
        header_acc = nil
      else
        table.insert(header_acc, line)
      end
    elseif in_marker then
      -- Markers close on a line that is exactly `-->`; content lines
      -- merely containing `-->` (diffs, prose) must not close early.
      if line:match("^%-%->$") then
        in_marker = false
      end
    else
      local header = line:match("^<!%-%- yap:tool (.+) %-%->%s*$")
      if header and role == "assistant" then
        local ok, h = pcall(vim.json.decode, header)
        if ok and type(h) == "table" and h.id and h.name then
          tool = { name = h.name, args = h.arguments, result = {} }
        else
          skipping = true
          vim.notify("yap: malformed yap:tool header, region skipped", vim.log.levels.WARN)
        end
      elseif line:match("^<!%-%- yap:tool%s*$") and role == "assistant" then
        header_acc = {} -- multi-line header form (long calls)
      elseif line:match("^<!%-%- yap:tool") then
        skipping = true -- region outside an assistant block: orphan, skip
      elseif line:match("^<!%-%- yap:%a+") then
        -- Single-line markers (`<!-- yap:usage {...} -->`) close on the
        -- same line; otherwise the next content line would be swallowed.
        in_marker = not line:match("%-%->")
      else
        local r = line:match(HEAD)
        if r and roles[r] then
          flush()
          role = roles[r]
        else
          table.insert(acc, line)
        end
      end
    end
  end
  flush()

  return messages
end

-- ─── Streaming append ──────────────────────────────────────────────────────

function M.append_text(buf, text)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local row = vim.api.nvim_buf_line_count(buf) - 1
  local col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  vim.api.nvim_buf_set_text(buf, row, col, row, col, vim.split(text, "\n", { plain = true }))
end

--- Windows whose cursor sits on the last line of `buf`: the user is
--- "following" the end of the conversation (pressed G, or was left there
--- by the previous chunk). Sampled BEFORE an append, because following
--- itself moves the cursor to the end.
function M.following_windows(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local wins = {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, w)
    if ok and cur[1] >= count then
      wins[#wins + 1] = w
    end
  end
  return wins
end

--- Before changing the buffer, remove windows whose cursor no longer matches
--- the exact tail position Yap last requested. That difference is explicit
--- user movement; checking synchronously avoids CursorMoved event races.
function M.cancel_moved_followers(buf, wins, expected)
  for i = #wins, 1, -1 do
    local w = wins[i]
    if not vim.api.nvim_win_is_valid(w) or vim.api.nvim_win_get_buf(w) ~= buf then
      expected[w] = nil
      table.remove(wins, i)
    else
      local want = expected[w]
      local ok, cur = pcall(vim.api.nvim_win_get_cursor, w)
      if not ok or (want and (cur[1] ~= want[1] or cur[2] ~= want[2])) then
        expected[w] = nil
        table.remove(wins, i)
      end
    end
  end
end

--- Keep follower windows on the real stream end at column zero. Windows that
--- did not start at the tail, or were removed by cancel_moved_followers, are
--- never moved.
function M.follow_windows(buf, wins, expected)
  if #wins == 0 or vim.api.nvim_get_mode().mode ~= "n" then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  for i = #wins, 1, -1 do
    local w = wins[i]
    if not vim.api.nvim_win_is_valid(w) or vim.api.nvim_win_get_buf(w) ~= buf then
      expected[w] = nil
      table.remove(wins, i)
    else
      expected[w] = { count, 0 }
      local ok = pcall(vim.api.nvim_win_set_cursor, w, expected[w])
      if not ok then
        expected[w] = nil
        table.remove(wins, i)
      end
    end
  end
end

--- Append whole lines as a new block, separated from the buffer's current
--- end by exactly one blank line (R7), no matter how the buffer ends.
--- All structural appends (headings, error markers) go through here.
function M.append_block(buf, block)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local n = vim.api.nvim_buf_line_count(buf)
  local keep = n
  while keep > 1 and vim.api.nvim_buf_get_lines(buf, keep - 1, keep, false)[1] == "" do
    keep = keep - 1
  end
  local lines = vim.deepcopy(block)
  table.insert(lines, 1, "")
  vim.api.nvim_buf_set_lines(buf, keep, n, false, lines)
end


return M

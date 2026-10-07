-- Run in a flickering window: :luafile /opt/code/yap/tests/fold_diagnostic.lua
-- While output streams, leave that window open. Then run :FoldDiagStop.
-- A scratch report opens; it contains fold metadata, not buffer text.
-- Run again in an ordinary file to compare. :FoldDiagReport previews without stopping.
local api = vim.api
if _G.yap_fold_diagnostic then
  _G.yap_fold_diagnostic.stop()
end

local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
local events, last, samples, edits = {}, nil, 0, 0
local timer = vim.uv.new_timer()
local active = true
local started = vim.uv.hrtime()
local function record(line)
  events[#events + 1] = string.format("+%.0fms %s", (vim.uv.hrtime() - started) / 1e6, line)
  if #events > 300 then
    table.remove(events, 1)
  end
end
local function sample(source)
  if
    not active
    or not api.nvim_buf_is_valid(buf)
    or not api.nvim_win_is_valid(win)
    or api.nvim_win_get_buf(win) ~= buf
  then
    return
  end
  samples = samples + 1
  api.nvim_win_call(win, function()
    local tick = api.nvim_buf_get_changedtick(buf)
    local cursor = api.nvim_win_get_cursor(win)[1]
    local positions = { cursor }
    -- Check recent Yap regions plus the one under the cursor. No text is read into the report.
    local fold = package.loaded["harness.fold"]
    local expected = {}
    if fold and vim.wo.foldtext:find("harness.fold", 1, true) then
      local ok, p = pcall(fold.parse, buf)
      if ok then
        for i = math.max(1, #p.regions - 11), #p.regions do
          local d = p.regions[i]
          positions[#positions + 1] = d.start
          expected[d.start] = d.finish or p.count
        end
        for _, d in ipairs(p.regions) do
          if d.start <= cursor and cursor <= (d.finish or p.count) then
            positions[#positions + 1] = d.start
            expected[d.start] = d.finish or p.count
            break
          end
        end
      end
    end
    local parts, seen = {}, {}
    for _, row in ipairs(positions) do
      if row >= 1 and row <= api.nvim_buf_line_count(buf) and not seen[row] then
        seen[row] = true
        local closed = vim.fn.foldclosed(row)
        local finish = vim.fn.foldclosedend(row)
        local level = vim.fn.foldlevel(row)
        local want = expected[row]
        parts[#parts + 1] = string.format(
          "%d:%d-%d/L%d%s%s",
          row,
          closed,
          finish,
          level,
          want and ("/expected=" .. want) or "",
          want and closed == row and finish ~= want and " MISMATCH" or ""
        )
      end
    end
    local signature = string.format(
      "tick=%d cursor=%d method=%s enabled=%s %s",
      tick,
      cursor,
      vim.wo.foldmethod,
      tostring(vim.wo.foldenable),
      table.concat(parts, " ")
    )
    if signature ~= last then
      record(string.format("%s %s", source, signature))
      last = signature
    end
  end)
end
local function report()
  local lines = {
    "Fold diagnostic (buffer number " .. buf .. ", window " .. win .. ")",
    string.format(
      "Samples: %d; buffer edits observed: %d; retained state changes: %d (last 300)",
      samples,
      edits,
      #events
    ),
    "Notation row:closed-start-closed-end/Lfoldlevel/expected-model-end; -1 means not closed.",
    "MISMATCH means a CLOSED Yap fold ends at a different row than its parsed region.",
    "Polling and scheduled callbacks cannot observe transitions entirely within one redraw/event-loop turn.",
    "No buffer contents are recorded. Inspect the report before sharing; option provenance can include paths.",
    "",
    "Option/mapping provenance (captured in the original window):",
  }
  if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    api.nvim_win_call(win, function()
      for _, command in ipairs({
        "verbose setlocal foldmethod? foldexpr? foldtext? foldlevel? foldenable?",
        "verbose nmap za",
        "verbose nmap <Tab>",
      }) do
        local ok, result = pcall(api.nvim_exec2, command, { output = true })
        lines[#lines + 1] = command
        vim.list_extend(lines, vim.split(ok and result.output or tostring(result), "\n", { plain = true }))
      end
      local ufo = package.loaded.ufo
      local ok, attached = ufo and pcall(ufo.hasAttached, buf)
      lines[#lines + 1] = "ufo loaded=" .. tostring(ufo ~= nil) .. " attached=" .. tostring(ok and attached or false)
    end)
  else
    lines[#lines + 1] = "Original window no longer shows the buffer."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Timeline (milliseconds since diagnostic start):"
  vim.list_extend(lines, events)
  local out = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(out, 0, -1, false, lines)
  vim.bo[out].modifiable = false
  vim.bo[out].filetype = "text"
  vim.cmd("botright new")
  api.nvim_win_set_buf(0, out)
  vim.bo[out].bufhidden = "wipe"
end
local function stop()
  if not active then
    return
  end
  sample("stop")
  active = false
  timer:stop()
  timer:close()
  pcall(api.nvim_buf_detach, buf)
  pcall(api.nvim_del_user_command, "FoldDiagStop")
  pcall(api.nvim_del_user_command, "FoldDiagReport")
  report()
end
_G.yap_fold_diagnostic = { stop = stop }
api.nvim_buf_attach(buf, false, {
  on_lines = function()
    edits = edits + 1
    vim.schedule(function()
      sample("edit")
    end)
  end,
  on_detach = function()
    if active then
      active = false
      timer:stop()
      timer:close()
    end
  end,
})
timer:start(
  0,
  100,
  vim.schedule_wrap(function()
    sample("poll")
  end)
)
api.nvim_create_user_command("FoldDiagStop", stop, {})
api.nvim_create_user_command("FoldDiagReport", report, {})
print("Fold diagnostic started for buffer " .. buf .. "; run :FoldDiagStop after the flicker.")

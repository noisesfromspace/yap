-- Session maintenance: keep the conversation inside the context window.
--
-- :YapClear replaces old tool-result bodies with an audit-log pointer;
-- :YapCompact inserts a summary prompt, sends it, then offers to delete the
-- superseded history. Both are ordinary (undoable) buffer edits.

local M = {}

local state = require("harness.state")
local template = require("harness.agent.template")
local paths = require("harness.path")
local session = require("harness.session")

local running = state.running

local HEAD = "^# @(%a+)%s*$"


--- :YapClear [keep] — replace the bodies of all but the last `keep`
--- (default 2) yap:tool regions with a placeholder; the full output
--- stays in the audit log. Headers (flattened into the model's transcript)
--- and yap:ui diffs stay. This is the one sanctioned rewrite of
--- existing lines (R-live-output-audit): the user owns the document, and clearing old
--- tool output is what keeps long sessions inside the context window.
function M.clear(buf, keep)
  buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
  if running[buf] then
    vim.notify("yap: turn running; stop it before clearing old tool output", vim.log.levels.WARN)
    return
  end
  keep = keep or 2
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Map tool-call ids to their JSONL line range (tool_call → tool_result)
  -- so each placeholder can point at the exact lines it replaced.
  local by_id = {}
  local apath = paths.audit_path(buf)
  if vim.fn.filereadable(apath) == 1 then
    for n, line in ipairs(vim.fn.readfile(apath)) do
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" and ev.id then
          local entry = by_id[ev.id]
          if not entry then
            entry = {}
            by_id[ev.id] = entry
          end
          entry.first = entry.first or n
          entry.last = n
        end
      end
    end
  end
  local function ref_for(id)
    local entry = id and by_id[id] or nil
    if entry and entry.last then
      if entry.first and entry.first ~= entry.last then
        return ("%s:%d-%d"):format(vim.fn.fnamemodify(apath, ":~"), entry.first, entry.last)
      end
      return ("%s:%d"):format(vim.fn.fnamemodify(apath, ":~"), entry.last)
    end
    return vim.fn.fnamemodify(apath, ":~") .. ":?"
  end
  -- collect tool regions as { first body line, last body line, header } (1-based,
  -- inclusive); the body runs from after the header to the yap:ui
  -- opener or the region closer
  local regions = {}
  local i = 1
  while i <= #lines do
    local body_start, header
    if lines[i]:match("^<!%-%- yap:tool .+ %-%->%s*$") then
      header = lines[i]:match("^<!%-%- yap:tool (.+) %-%->%s*$")
      body_start = i + 1 -- single-line header
    elseif lines[i]:match("^<!%-%- yap:tool%s*$") then
      local acc = {}
      local j = i + 1 -- multi-line header: body after its closing -->
      while j <= #lines and not lines[j]:match("^%-%->%s*$") do
        acc[#acc + 1] = lines[j]
        j = j + 1
      end
      header = table.concat(acc, "\n")
      body_start = j + 1
    end
    if body_start then
      local j = body_start
      while j <= #lines and not lines[j]:match("^<!%-%- yap:ui") and not lines[j]:match("^<!%-%- /yap:tool") do
        j = j + 1
      end
      table.insert(regions, { body_start, j - 1, header = header })
      i = j
    else
      i = i + 1
    end
  end
  local cleared = 0
  for r = 1, #regions - keep do
    local s, e = regions[r][1], regions[r][2]
    if e >= s and not lines[s]:match("^%[output cleared") then
      local id
      local ok_h, h = pcall(vim.json.decode, regions[r].header or "")
      if ok_h and type(h) == "table" then
        id = h.id
      end
      local placeholder = ("[output cleared — full output in the audit log: %s]"):format(ref_for(id))
      vim.api.nvim_buf_set_lines(buf, s - 1, e, false, { placeholder })
      cleared = cleared + 1
      local delta = (e - s + 1) - 1 -- replaced that many lines with one
      for r2 = r + 1, #regions do
        regions[r2][1], regions[r2][2] = regions[r2][1] - delta, regions[r2][2] - delta
      end
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  if cleared > 0 then
    session.save(buf)
  end
end

--- The compaction prompt: a `compact` template in templates_dir overrides
--- the built-in default (compaction is the template mechanism applied,
--- R-templates-skills). Returns trimmed body lines, never a leading # @role heading.
local function compact_prompt_lines()
  local lines = template.named_lines("compact")
  if not lines then
    lines = vim.split(
      "Summarize the conversation above into a compact markdown summary that\n"
        .. "preserves all facts, decisions, open todos, and current file state.\n"
        .. "I will use that summary to continue the conversation with full context.",
      "\n",
      { plain = true }
    )
  end
  vim.list_extend(lines, {
    "Do not use the colon character anywhere in the summary. Avoid YAML/frontmatter delimiters, Markdown headings, code fences, and HTML comments. Use simple prose or basic bullets so the summary stays safe for Markdown Tree-sitter parsing.",
  })
  return lines
end

--- :YapCompact — compaction as the visible, editable recipe, automated:
--- insert the compact prompt, send it, then offer to delete the superseded
--- history once the summary has streamed in. The summary stays a visible
--- # @assistant turn; the deletion is an ordinary (undoable) buffer edit,
--- never a hidden archive (see |yap-compact|).
function M.compact()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: not a yap buffer", vim.log.levels.WARN)
    return
  end
  if running[buf] then
    vim.notify("yap: turn running; stop it before compacting", vim.log.levels.WARN)
    return
  end
  template.append_as_message(buf, compact_prompt_lines())
  vim.b[buf].yap_compact_pending = true
  require("harness").send()
end

--- Offer to drop the history the summary superseded (asked once the
--- summary has finished streaming; the summary is never touched).
function M.offer(buf)
  vim.ui.select({ "Delete history", "Keep history" }, {
    prompt = "yap: compact — delete the superseded history? (the summary stays)",
  }, function(choice)
    if choice == "Delete history" then
      M.delete(buf)
    end
  end)
end

--- Delete every message between the system message and the final summary
--- (the last # @assistant message), leaving frontmatter + system message +
--- summary + the trailing # @user prompt. Blank-line separation is R-blank-lines.
function M.delete(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ai
  for i = #lines, 1, -1 do
    if lines[i]:match("^# @assistant%s*$") then
      ai = i
      break
    end
  end
  if not ai then
    vim.notify("yap: no assistant summary to keep", vim.log.levels.WARN)
    return
  end
  -- Keep frontmatter + the system message: the system message ends at the
  -- first heading after # @system; with no system message, keep only the
  -- frontmatter (everything before the first heading).
  local se = 0
  for i = 1, #lines do
    if lines[i]:match("^# @system%s*$") then
      for j = i + 1, #lines do
        if lines[j]:match(HEAD) then
          se = j - 1
          break
        end
      end
      if se == 0 then
        se = #lines -- system message runs to the end (no later heading)
      end
      break
    elseif lines[i]:match(HEAD) then
      se = i - 1 -- no system message: keep frontmatter only
      break
    end
  end
  while se > 0 and lines[se]:match("^%s*$") do
    se = se - 1
  end
  local kept = {}
  for i = 1, se do
    kept[#kept + 1] = lines[i]
  end
  kept[#kept + 1] = "" -- one blank line between system and summary (R-blank-lines)
  for i = ai, #lines do
    kept[#kept + 1] = lines[i]
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, kept)
  session.save(buf)
end

return M

-- Session maintenance: keep the conversation inside the context window.
--
-- :YapClear replaces old tool-result bodies with an audit-log pointer;
-- :YapCompact inserts a summary prompt, sends it, then offers to delete the
-- superseded history. Both are ordinary (undoable) buffer edits.

local M = {}

local state = require("harness.state")
local structure = require("harness.model.structure")
local template = require("harness.client.template")
local paths = require("harness.path")
local session = require("harness.session")

local running = state.running

--- :YapClear [keep] — replace the bodies of all but the last `keep`
--- (default 2) yap:tool regions with a placeholder; the full output
--- stays in the audit log. Headers (flattened into the model's transcript)
--- and yap:ui diffs stay. This is the one sanctioned rewrite of
--- existing lines (R-live-output-tail): the user owns the document, and clearing old
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
  -- collect tool regions as { body first..last, header }; the body is the
  -- result text only — the structural parse already excludes the header and
  -- the paired `yap:ui` diff, and sees through fences (a `<!-- yap:tool`
  -- quoted inside a fenced result is content, not a region).
  local regions = structure.tool_regions(buf)
  -- Clear from the bottom up so earlier regions keep their line numbers:
  -- an edit at a region only shifts lines BELOW it, which have already been
  -- processed. The `lines` snapshot read above stays valid for the
  -- idempotency check (a region already replaced by a placeholder is
  -- skipped). This removes the old full-buffer re-read per region — an
  -- O(regions × n) loop that froze the editor on sessions with thousands
  -- of tool calls.
  local cleared = 0
  for r = #regions - keep, 1, -1 do
    local s, e = regions[r].body_start, regions[r].body_finish
    if e >= s and not lines[s]:match("^%[output cleared") then
      local placeholder = ("[output cleared — full output in the audit log: %s]"):format(ref_for(regions[r].id))
      vim.api.nvim_buf_set_lines(buf, s - 1, e, false, { placeholder })
      cleared = cleared + 1
    end
  end
  if cleared > 0 then
    session.save(buf)
  end
end

--- The compaction prompt: a `compact` template in templates_dir overrides
--- the built-in default (compaction is the template mechanism applied,
--- R-templates-skills). Returns trimmed body lines, never a leading # @role heading.
local function compact_prompt_lines(instructions)
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
  if instructions and instructions:match("%S") then
    vim.list_extend(lines, { "", "Additional instructions: " .. instructions })
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
function M.compact(instructions)
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].yap then
    vim.notify("yap: not a yap buffer", vim.log.levels.WARN)
    return
  end
  if running[buf] then
    vim.notify("yap: turn running; stop it before compacting", vim.log.levels.WARN)
    return
  end
  template.append_as_message(buf, compact_prompt_lines(instructions))
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
  local headings = structure.parse(buf).headings
  local ai
  for i = #headings, 1, -1 do
    if headings[i].role == "assistant" then
      ai = headings[i].line
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
  local first = headings[1]
  if first and first.role == "system" then
    se = headings[2] and headings[2].line - 1 or #lines
  elseif first then
    se = first.line - 1
  end
  while se > 0 and lines[se]:match("^%s*$") do
    se = se - 1
  end
  -- Delete the superseded history as one range edit, leaving a single blank
  -- line between the system message and the summary (R-blank-lines). A range
  -- delete (rather than rebuilding the whole buffer through a `kept` table)
  -- is O(deleted) not O(buffer), and preserves the frontmatter/system/summary
  -- extmarks (folds, etc.) instead of deleting and recreating them.
  vim.api.nvim_buf_set_lines(buf, se, ai - 1, false, { "" })
  session.save(buf)
end

return M

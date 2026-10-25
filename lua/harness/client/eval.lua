-- :YapEval! — a one-shot, stateless filter over the current selection.
-- The selected lines are sent to the eval model with no tools; the returned
-- text replaces the selection in place (`!`-semantics, but asynchronous and
-- undoable like any other buffer edit).
--
-- With a linewise range (a visual selection or an explicit `:1,5`):
--   - In a yap session buffer the replacement is wrapped as a single
--     `# @assistant` message, so a selection of turns collapses to a summary.
--   - In any other buffer it is plain text, so the same command refactors a
--     function without leaving a stray heading behind.
--
-- With no range, the model's output is inserted at the cursor as new lines —
-- "generate three fake addresses" fills a fresh, empty (No Name) buffer.
--
-- :YapEval (no bang) is the interactive counterpart: see M.session.

local M = {}

local structure = require("harness.model.structure")

local function config()
  return require("harness").config
end

local EVAL_SYSTEM = [[You follow the instruction exactly and return ONLY the result: the replacement text when transforming the provided text, the new content when generating. Do not add any explanation, preamble, sign-off, Markdown code fence, or message heading.]]

--- Instruction applied when :YapEval! gets a selection but no instruction: the
--- selection itself is the input, so a visual-mode eval just filters it.
local DEFAULT_INSTRUCTION = "Improve this text"

--- :YapEval! uses flash when set, otherwise agent.
function M.combo()
  local provider, model = require("harness.config").group("flash")
  if not provider then
    provider, model = require("harness.config").group("agent")
  end
  return provider, model
end

--- The user message: instruction plus the selected text. A non-session
--- buffer adds a file/language header so the model has context.
function M.build_user(buf, instruction, selected)
  local parts = {}
  if not vim.b[buf].yap then
    local name = vim.api.nvim_buf_get_name(buf)
    local rel = name
    if name ~= "" and not name:match("^%a+://") then
      rel = vim.fs.relpath(vim.fn.getcwd(), name) or name
    end
    local ft = vim.bo[buf].filetype or ""
    if rel ~= "" then
      parts[#parts + 1] = "File: " .. rel .. (ft ~= "" and (" (language: " .. ft .. ")") or "")
    end
  end
  parts[#parts + 1] = instruction
  parts[#parts + 1] = selected
  return table.concat(parts, "\n\n")
end

--- Decode a completed `yap send` result into body lines, or nil after
--- surfacing the failure (error / empty output). Marker stripping and
--- trimming are shared by both the replace and insert paths.
function M.decode(result)
  if result.code ~= 0 then
    vim.notify("yap eval: " .. ((result.stderr or ""):gsub("%s+$", "")), vim.log.levels.ERROR)
    return nil
  end
  local text = structure.strip_markers(result.stdout or "")
  text = text:gsub("^\n+", ""):gsub("\n+$", "")
  if text == "" then
    vim.notify("yap eval: the model returned no output", vim.log.levels.WARN)
    return nil
  end
  return vim.split(text, "\n", { plain = true })
end

--- Replace the selection with the completed response, guarding against the
--- selection having changed while the eval was in flight.
function M.finish(buf, line1, line2, sent, result)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local body = M.decode(result)
  if not body then
    return
  end
  local now = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  if not vim.deep_equal(now, sent) then
    vim.notify("yap eval: selection changed while it ran; result not applied", vim.log.levels.WARN)
    return
  end
  local replacement
  if vim.b[buf].yap then
    replacement = { "# @assistant", "" }
    vim.list_extend(replacement, body)
    replacement[#replacement + 1] = ""
  else
    replacement = body
  end
  vim.api.nvim_buf_set_lines(buf, line1 - 1, line2, false, replacement)
end

--- Insert the completed response as new lines before `row` (0-based).
function M.insert(buf, row, result)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local body = M.decode(result)
  if not body then
    return
  end
  vim.api.nvim_buf_set_lines(buf, row, row, false, body)
end

--- The opening user turn of an interactive eval session: the file context
--- and the selected lines in a fence (longer than any backtick run inside),
--- then the instruction — or a blank line for the user to write one.
function M.session_user(buf, line1, line2, instruction)
  local parts = {}
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and not name:match("^%a+://") then
    name = vim.fs.relpath(vim.fn.getcwd(), name) or name
  end
  local ft = vim.bo[buf].filetype or ""
  if line1 then
    local sel = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
    local where = (name ~= "" and name or "[No Name]") .. ":" .. line1 .. "-" .. line2
    parts[#parts + 1] = "From " .. where .. (ft ~= "" and (" (language: " .. ft .. ")") or "") .. ":"
    parts[#parts + 1] = ""
    local longest = 2
    for _, l in ipairs(sel) do
      for run in l:gmatch("`+") do
        longest = math.max(longest, #run)
      end
    end
    local fence = string.rep("`", longest + 1)
    parts[#parts + 1] = fence .. ft
    vim.list_extend(parts, sel)
    parts[#parts + 1] = fence
    parts[#parts + 1] = ""
  elseif name ~= "" then
    parts[#parts + 1] = "File: " .. name .. (ft ~= "" and (" (language: " .. ft .. ")") or "")
    parts[#parts + 1] = ""
  end
  parts[#parts + 1] = instruction or ""
  return parts
end

--- :YapEval — open an interactive eval session in a split: a regular yap
--- session (default system prompt, tools, follow-ups, listed in
--- sessions()). The selection is context only; the source buffer is never
--- changed. With an instruction the first turn is sent immediately,
--- otherwise the cursor waits at the end of the user turn.
function M.session(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line1, line2 = opts.line1, opts.line2
  if line1 and line2 and line1 > line2 then
    line1, line2 = line2, line1
  end
  local instruction = opts.instruction ~= "" and opts.instruction or nil
  local user = M.session_user(buf, line1, line2, instruction)
  local yap = require("harness")
  local sbuf = yap.new({ hidden = true })
  vim.api.nvim_buf_set_lines(sbuf, -2, -1, false, user)
  -- Save the quoted selection now so the session is listed in sessions()
  -- before its first send.
  require("harness.session").save(sbuf)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, sbuf)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(sbuf), 0 })
  if instruction then
    yap.send(sbuf)
  end
  return sbuf
end

--- Evaluate lines line1..line2 (1-based, inclusive) in `buf` (defaults to the
--- current buffer): replace them with the model's output for `instruction`.
--- With no line range, generate instead: insert the output at the cursor.
--- When `instruction` is empty or omitted, a selection is transformed with a
--- default instruction; with no selection it is asked for via vim.ui.input.
function M.eval(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local replace = opts.line1 and opts.line2
  local line1, line2, sent, insert_row
  if replace then
    line1, line2 = opts.line1, opts.line2
    if line1 > line2 then
      line1, line2 = line2, line1
    end
    sent = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  else
    -- Insert at the cursor line when the window shows this buffer, else
    -- append at the end (a plain Lua call against a background buffer).
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == buf then
      insert_row = vim.api.nvim_win_get_cursor(win)[1] - 1
    else
      insert_row = vim.api.nvim_buf_line_count(buf)
    end
  end
  local selected = replace and table.concat(sent, "\n") or ""

  local function run(instruction)
    if instruction == "" then
      return
    end
    local provider, model = M.combo()
    if not provider then
      vim.notify("yap eval: no model configured (set model_groups.flash)", vim.log.levels.ERROR)
      return
    end
    local payload = vim.json.encode({
      messages = {
        { role = "system", content = EVAL_SYSTEM },
        { role = "user", content = M.build_user(buf, instruction, selected) },
      },
      tools = {},
    }) .. "\n"
    vim.notify("running…", vim.log.levels.INFO, { title = "yap eval" })
    vim.system(
      { config().bin, "send", "--provider", provider, "--model", model },
      { stdin = payload, text = true },
      vim.schedule_wrap(function(result)
        if replace then
          M.finish(buf, line1, line2, sent, result)
        else
          M.insert(buf, insert_row, result)
        end
      end)
    )
  end

  if opts.instruction and opts.instruction ~= "" then
    run(opts.instruction)
  elseif replace then
    -- A selection with no instruction: read the selection and transform it
    -- with a default, so a visual-mode :YapEval! does not prompt.
    run(DEFAULT_INSTRUCTION)
  else
    vim.ui.input({ prompt = "yap eval: " }, function(input)
      if input and input ~= "" then
        run(input)
      end
    end)
  end
end

return M

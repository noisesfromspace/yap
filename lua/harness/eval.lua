-- :YapEval — a one-shot, stateless filter over the current selection.
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

local M = {}

local function config()
  return require("harness").config
end

local EVAL_SYSTEM = [[You follow the instruction exactly and return ONLY the result: the replacement text when transforming the provided text, the new content when generating. Do not add any explanation, preamble, sign-off, Markdown code fence, or message heading.]]

--- Instruction applied when :YapEval gets a selection but no instruction: the
--- selection itself is the input, so a visual-mode eval just filters it.
local DEFAULT_INSTRUCTION = "Improve this text"

--- Strip `<!-- yap:* -->` marker regions (thinking/model/error) from a
--- one-shot `yap send` response, preserving any other HTML in the answer.
--- Exported for tests.
function M.strip_markers(text)
  local out = {}
  local in_marker = false
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if in_marker then
      if line == "-->" then
        in_marker = false
      end
    elseif line:match("^<!%-%- /?yap:") then
      if not line:match("%-%->%s*$") then
        in_marker = true
      end
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

--- The provider/model combo for an eval: the dedicated `eval_model` when
--- configured, else the buffer's current combo (a session's model, or the
--- setup() default for a plain buffer).
function M.combo(buf)
  local cfg = config()
  local provider, model = require("harness.config").parse_combo(cfg.eval_model or "")
  if not provider then
    provider, model = require("harness.config").current_combo(buf)
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
  local text = M.strip_markers(result.stdout or "")
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

--- Open the eval as a real yap session in a split, kept out of the
--- :YapSessions picker by living under the hidden `<project>/.eval/` folder
--- (the picker globs `*/session.md` one level deep). The buffer holds the
--- eval's system prompt and user turn; the raw `yap send` stream (thinking,
--- model and error markers included) is appended as the `# @assistant`
--- reply, so follow-ups are ordinary sends. :YapFork copies it into a
--- listed session. Returns the session buffer, an append function for
--- stream chunks, and a done function that closes the turn and saves.
function M.open_session(provider, model, user)
  local paths = require("harness.path")
  local document = require("harness.document")
  local yap = require("harness")
  local cur = vim.api.nvim_get_current_win()
  local sbuf = yap.new({
    provider = provider,
    model = model,
    system = EVAL_SYSTEM,
    path = paths.new_session_path(paths.session_dir(vim.fn.getcwd()) .. "/.eval"),
    hidden = true,
  })
  vim.api.nvim_buf_set_lines(sbuf, -2, -1, false, vim.split(user, "\n", { plain = true }))
  document.append_lines(sbuf, { "# @assistant", "" })
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, sbuf)
  vim.api.nvim_set_current_win(cur)
  local function follow()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == sbuf then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(sbuf), 0 })
    end
  end
  follow()
  local function append(chunk)
    document.append_text(sbuf, chunk)
    follow()
  end
  local function done()
    if not vim.api.nvim_buf_is_valid(sbuf) then
      return
    end
    document.append_lines(sbuf, { "# @user", "" })
    follow()
    require("harness.session").save(sbuf)
  end
  return sbuf, append, done
end

--- Evaluate lines line1..line2 (1-based, inclusive) in `buf` (defaults to the
--- current buffer): replace them with the model's output for `instruction`.
--- With no line range, generate instead: insert the output at the cursor.
--- When `instruction` is empty or omitted, a selection is transformed with a
--- default instruction; with no selection it is asked for via vim.ui.input.
--- With `show`, the response streams into a hidden eval session in a split
--- (see open_session), where follow-up questions can be asked.
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
    local provider, model = M.combo(buf)
    if not provider then
      vim.notify("yap eval: no model configured (set eval_model)", vim.log.levels.ERROR)
      return
    end
    local user = M.build_user(buf, instruction, selected)
    local payload = vim.json.encode({
      messages = {
        { role = "system", content = EVAL_SYSTEM },
        { role = "user", content = user },
      },
      tools = {},
    }) .. "\n"
    vim.notify("running…", vim.log.levels.INFO, { title = "yap eval" })
    local sys_opts = { stdin = payload, text = true }
    local chunks, done
    if opts.show then
      -- A stdout callback means result.stdout is nil, so collect the chunks
      -- for the replace/insert step as well as streaming them.
      chunks = {}
      local append
      _, append, done = M.open_session(provider, model, user)
      sys_opts.stdout = function(_, data)
        if data then
          chunks[#chunks + 1] = data
          vim.schedule(function()
            append(data)
          end)
        end
      end
    end
    vim.system(
      { config().bin, "send", "--provider", provider, "--model", model },
      sys_opts,
      vim.schedule_wrap(function(result)
        if chunks then
          result.stdout = table.concat(chunks)
          done()
        end
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
    -- with a default, so a visual-mode :YapEval does not prompt.
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

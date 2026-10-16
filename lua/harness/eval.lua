-- :YapEval — a one-shot, stateless filter over the current selection.
-- The selected lines are sent to the eval model with no tools; the returned
-- text replaces the selection in place (`!`-semantics, but asynchronous and
-- undoable like any other buffer edit).
--
-- In a yap session buffer the replacement is wrapped as a single
-- `# @assistant` message, so a selection of turns collapses to a summary;
-- in any other buffer it is plain text, so the same command refactors a
-- function without leaving a stray heading behind.

local M = {}

local function config()
  return require("harness").config
end

local EVAL_SYSTEM = [[You transform the provided text exactly as instructed and return ONLY the replacement text. Do not add any explanation, preamble, sign-off, Markdown code fence, or message heading.]]

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
--- configured, else the buffer's current combo.
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

--- Replace the selection with the completed response, guarding against the
--- selection having changed while the eval was in flight.
function M.finish(buf, line1, line2, sent, result)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if result.code ~= 0 then
    vim.notify("yap eval: " .. ((result.stderr or ""):gsub("%s+$", "")), vim.log.levels.ERROR)
    return
  end
  local text = M.strip_markers(result.stdout or "")
  text = text:gsub("^\n+", ""):gsub("\n+$", "")
  if text == "" then
    vim.notify("yap eval: the model returned no output", vim.log.levels.WARN)
    return
  end
  local now = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  if not vim.deep_equal(now, sent) then
    vim.notify("yap eval: selection changed while it ran; result not applied", vim.log.levels.WARN)
    return
  end
  local body = vim.split(text, "\n", { plain = true })
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

--- Evaluate lines line1..line2 (1-based, inclusive) in `buf` (defaults to the
--- current buffer): replace them with the model's output for `instruction`.
--- When `instruction` is empty or omitted, ask for it with vim.ui.input.
function M.eval(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line1, line2 = opts.line1, opts.line2
  if not line1 or not line2 then
    vim.notify("yap eval: needs a line range (select lines first)", vim.log.levels.WARN)
    return
  end
  if line1 > line2 then
    line1, line2 = line2, line1
  end
  local sent = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  local selected = table.concat(sent, "\n")

  local function run(instruction)
    if instruction == "" then
      return
    end
    local provider, model = M.combo(buf)
    if not provider then
      vim.notify("yap eval: no model configured (set eval_model)", vim.log.levels.ERROR)
      return
    end
    local payload = vim.json.encode({
      messages = {
        { role = "system", content = EVAL_SYSTEM },
        { role = "user", content = M.build_user(buf, instruction, selected) },
      },
      tools = {},
    }) .. "\n"
    vim.system(
      { config().bin, "send", "--provider", provider, "--model", model },
      { stdin = payload, text = true },
      vim.schedule_wrap(function(result)
        M.finish(buf, line1, line2, sent, result)
      end)
    )
  end

  if opts.instruction and opts.instruction ~= "" then
    run(opts.instruction)
  else
    vim.ui.input({ prompt = "yap eval: " }, function(input)
      if input and input ~= "" then
        run(input)
      end
    end)
  end
end

return M

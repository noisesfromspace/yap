-- Session titling: generate the one-line description shown in the winbar and
-- session picker, by asking a small model to label the latest user request
-- ("user") and a bigger model to summarize the whole session ("answer").

local M = {}

local frontmatter = require("harness.frontmatter")
local document = require("harness.document")
local config = require("harness.config")
local view = require("harness.view")

local function harness()
  return require("harness")
end

-- Latest description request per buffer, so a slow earlier summary cannot
-- clobber a newer one (send and turn-completion refreshes can overlap).
local description_seq = {}
local description_started = {}

-- Routine commit/close requests should not become the session's title when
-- an earlier user request explains what the work was actually about. Tool
-- calls and results are assistant transcript text, not user intent, so never
-- send them to the title model.
local function title_messages(messages)
  local user_indices = {}
  for i, message in ipairs(messages) do
    if message.role == "user" then
      user_indices[#user_indices + 1] = i
    end
  end
  if #user_indices == 0 then
    return {}, false, false
  end

  local latest = user_indices[#user_indices]
  local earlier_user = #user_indices > 1
  local text = view.collapse(messages[latest].content)
  local lower = text:lower()
  local replacement
  local housekeeping_only = false
  if lower:match("^commit changes from this session") or lower:match("^commit( and close)?[.!]?$") then
    replacement = nil
    housekeeping_only = true
  elseif earlier_user then
    replacement = lower:match("^(.-)%s+commit and close[.!]?$")
    if replacement then
      replacement = replacement:gsub("%s+$", "")
    end
  end

  local filtered = {}
  for _, i in ipairs(user_indices) do
    if i ~= latest then
      filtered[#filtered + 1] = messages[i]
    elseif replacement and replacement ~= "" then
      filtered[#filtered + 1] = { role = "user", content = replacement }
    elseif not housekeeping_only then
      filtered[#filtered + 1] = messages[i]
    end
  end
  return filtered, housekeeping_only or replacement ~= nil, housekeeping_only
end

local function current_description(buf)
  local e = frontmatter.end_line(buf)
  if not e then
    return ""
  end
  local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
  return fm and fm.description or ""
end

--- Generate or refresh the session description shown in the winbar and
--- session picker. `kind` selects the model and what it summarizes:
---   "user"   — smallest model, only the first useful request (runs once)
---   "answer" — bigger model, the ordered user-request history (runs after turns)
function M.refresh(buf, kind, messages)
  local combo, system, content
  local title_input, housekeeping = title_messages(messages or document.parse_buffer(buf))
  if kind == "user" then
    -- Generate an instant label only once, from the session's first useful
    -- request. Later turns are summarized by the whole-session stage below.
    if current_description(buf) ~= "" or description_started[buf] or (housekeeping and #title_input == 0) then
      return
    end
    combo = harness().config.description_model
    system = [[Write a short title for the user's request below.

Rules:
- 2-5 words, a specific noun phrase, not a sentence
- No leading "The user", no "how to", no trailing period
- No colon in the title (it breaks the YAML frontmatter)
- Example: "Add websearch tool", "Fix fold lag on streaming"

Return only the title.]]
    for _, message in ipairs(title_input) do
      if message.role == "user" then
        content = message.content
        break
      end
    end
    if not content or content == "" then
      return
    end
  else
    if #title_input == 0 then
      return
    end
    combo = harness().config.description_answer_model
    system = [[Write a short session title centered on the overall work, so the session is easy to find later.

The input is the user's requests in order. The first request anchors the session's main goal; later requests may refine or extend it. Summarize the overall work, not just the final request or workflow.

Rules:
- 2-6 words, a specific noun phrase, not a sentence, no trailing period
- No "session", "conversation", "the user", "about"
- Prefer "Subject – change" so titles stay distinct across sessions in the same project
- No colon in the title — it breaks the YAML frontmatter
- Routine commit/close instructions are housekeeping, not the session goal
- Never title from code, logs, or command output; do not use Markdown fences
- Example: "Fold lag – cache per changedtick"

Return only the title.]]
    local requests = {}
    for _, message in ipairs(title_input) do
      requests[#requests + 1] = message.content
    end
    local follow_ups = {}
    for i = 2, #requests do
      follow_ups[#follow_ups + 1] = requests[i]
    end
    content = vim.json.encode({ initial_request = requests[1], follow_up_requests = follow_ups })
  end
  if not combo or combo == "" then
    return
  end
  local provider, model = config.parse_combo(combo)
  if not provider then
    return
  end
  local seq = (description_seq[buf] or 0) + 1
  description_seq[buf] = seq
  if kind == "user" then
    description_started[buf] = true
  end
  local payload = vim.json.encode({
    messages = {
      { role = "system", content = system },
      { role = "user", content = content },
    },
  })
  vim.system(
    { harness().config.bin, "send", "--provider", provider, "--model", model },
    { stdin = payload, text = true },
    vim.schedule_wrap(function(result)
      if not vim.api.nvim_buf_is_valid(buf) or description_seq[buf] ~= seq then
        return
      end
      if result.code ~= 0 then
        return
      end
      local description = (result.stdout or ""):gsub("<!%-%-.-%-%->", "")
      description = view.collapse(description):gsub(":%s+", " – ")
      if description == "" or description:find("`", 1, true) then
        return
      end
      -- The prompts ask for a 2-6 word phrase, but a verbose model can
      -- still return a paragraph; hard-cap it so the frontmatter and
      -- picker stay readable. (No max_tokens cap: reasoning models spend
      -- the whole budget on reasoning and return an empty completion.)
      -- Counted in characters, not bytes: the `–` normalized above is
      -- multi-byte, and a byte slice can split it.
      if vim.fn.strchars(description) > 60 then
        description = vim.fn.strcharpart(description, 0, 59):gsub("%s+%S*$", "") .. "…"
      end
      local e = frontmatter.end_line(buf)
      if not e then
        return
      end
      local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, e, false))
      if not fm then
        return
      end
      local block = frontmatter.render(
        fm.provider,
        fm.model,
        fm.models,
        fm.created_at,
        fm.title,
        description,
        fm.agent,
        fm.tools,
        fm.subagents,
        fm.updated_at,
        fm.turns,
        fm.created_cwd,
        fm.forked_from,
        fm.forks,
        fm.subagent_parent,
        fm.assets,
        fm.reasoning_level
      )
      vim.api.nvim_buf_set_lines(buf, 0, e, false, block)
      require("harness.session").save(buf)
    end)
  )
end

--- Drop a buffer's in-flight description state (BufWipeout).
function M.forget(buf)
  description_seq[buf] = nil
  description_started[buf] = nil
end

return M

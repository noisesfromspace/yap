-- Subagent orchestration: spawn a child session for a `subagent_request`
-- event, run it, and report its final answer back to the parent's serve
-- process. Also owns tearing down every child when a parent is unloaded.

local M = {}

local state = require("harness.state")
local frontmatter = require("harness.model.frontmatter")
local config = require("harness.config")
local paths = require("harness.path")
local document = require("harness.model.document")

local function harness()
  return require("harness")
end

local subagent_children = state.subagent_children
local subagent_done = state.subagent_done
local errors = state.errors
local running = state.running
local servers = state.servers

-- The tools a subagent may request; agent-definition files also use the aliases
-- below (grep/find/webfetch) which are mapped onto these canonical names.
local ALLOWED_TOOLS = {
  "read",
  "search",
  "glob",
  "fetch",
  "bash",
  "curl",
  "write",
  "edit",
  "quickfix",
}

-- An agent definition with no `tools:` header gets this read-only set: a subagent is one
-- prompt-injection hop removed from the user's attention, so it must opt into
-- write/bash/curl explicitly. Any agent definition may still request the full
-- set (minus recursive `subagent`) via its `tools:` header.
local DEFAULT_SUBAGENT_TOOLS = { "read", "search", "glob", "fetch", "quickfix" }

local function subagent_result(parent, child, child_path, reply)
  return function(success)
    subagent_children[parent] = nil
    local result = "error: " .. (errors[child] or "subagent stopped without a result")
    if success then
      -- Only final prose, not the child's tool history, belongs in the parent.
      local text, in_comment, in_ui = {}, false, false
      for _, line in ipairs(vim.api.nvim_buf_get_lines(child, 0, -1, false)) do
        if line == "# @assistant" then
          text, in_comment, in_ui = {}, false, false
        elseif line:match("^<!%-%- /yap:tool") then
          text = {}
          in_comment, in_ui = false, false
        elseif in_ui then
          -- Display-only diff between the paired yap:ui markers.
          if line == "-->" or line:match("^<!%-%- /yap:ui") then
            in_ui = false
          end
        elseif line:match("^<!%-%- yap:ui") then
          in_ui = true
          in_comment = not line:match("%-%->$")
        elseif line:match("^<!%-%- yap:") then
          in_comment = not line:match("%-%->$")
        elseif in_comment then
          if line == "-->" then
            in_comment = false
          end
        elseif line:match("^<!%-%- /yap:") then
          -- Orphan region closer: a marker line is never part of the answer.
        elseif line ~= "# @user" then
          text[#text + 1] = line
        end
      end
      result = table.concat(text, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if result == "" then
        result = "error: subagent returned no final answer"
      end
    end
    reply("Session: [" .. child_path .. "](" .. child_path .. ")\n" .. result)
  end
end

--- Handle a `subagent_request` event: resume an owned child session, or
--- create a new one from an agent-definition file.
function M.start(parent, ev)
  local function reply(text)
    local process = servers[parent]
    if process then
      process:write(vim.json.encode({ type = "subagent_result", id = ev.id, result = text }) .. "\n")
    end
  end
  if type(ev.task) ~= "string" or ev.task:match("^%s*$") then
    reply("error: invalid subagent request")
    return
  end
  if ev.session and ev.session ~= "" then
    local parent_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(parent, 0, -1, false))
    local child_path = vim.fs.normalize(ev.session)
    local owned = false
    for _, path in ipairs(parent_fm and parent_fm.subagents or {}) do
      if vim.fs.normalize(path) == child_path then
        owned = true
        break
      end
    end
    if not owned or vim.fn.filereadable(child_path) == 0 then
      reply("error: subagent session not found in parent's subagents list")
      return
    end
    local child_fm = frontmatter.parse(vim.fn.readfile(child_path))
    if not child_fm or not child_fm.agent or (ev.agent and ev.agent ~= "" and ev.agent ~= child_fm.agent) then
      reply("error: subagent definition mismatch")
      return
    end
    local child = vim.fn.bufadd(child_path)
    vim.fn.bufload(child)
    if not vim.b[child].yap then
      harness().adopt(child, child_path)
    end
    if running[child] then
      reply("error: subagent session is already running")
      return
    end
    document.append_message(child, "user", vim.split(ev.task, "\n", { plain = true }))
    vim.b[child].yap_subagent_parent = parent
    vim.b[child].yap_subagent_task = ev.task
    require("harness.session").save(child)
    subagent_children[parent] = child
    subagent_done[child] = subagent_result(parent, child, child_path, reply)
    harness().send(child)
    return
  end
  if type(ev.agent) ~= "string" or not ev.agent:match("^[%w_-]+$") then
    reply("error: invalid subagent request")
    return
  end
  -- A per-call `model` runs the child on a combo the parent picked. Only a
  -- full provider/model pair is accepted: a bare name cannot be resolved to a
  -- provider, and — unlike a definition's `model` header — the override is
  -- expected to come from the `models` tool, which always returns full combos.
  -- Validated before the session is created so a typo costs nothing.
  local override_provider, override_model
  if type(ev.model) == "string" and ev.model ~= "" then
    override_provider, override_model = config.parse_combo(ev.model)
    if not override_provider then
      reply("error: invalid subagent model '" .. ev.model .. "': expected provider/model (see the models tool)")
      return
    end
  end
  local agent_file = paths.expand(harness().config.agents_dir) .. "/" .. ev.agent .. ".md"
  local ok_lines, lines = pcall(vim.fn.readfile, agent_file)
  if not ok_lines or #lines == 0 or lines[1] ~= "---" then
    reply("error: missing agent definition " .. ev.agent .. " (" .. agent_file .. ")")
    return
  end
  local header, closing = {}, nil
  for i = 2, #lines do
    if lines[i] == "---" then
      closing = i
      break
    end
    local key, value = lines[i]:match("^(%w+):%s*(.-)%s*$")
    if key then
      header[key] = value
    end
  end
  if not closing then
    reply("error: invalid agent definition " .. agent_file)
    return
  end
  local body = table.concat(vim.list_slice(lines, closing + 1), "\n")
  local provider, model = config.current_combo(parent)
  -- Pi agent definitions commonly use bare model names; Yap cannot infer their provider.
  -- Only a provider/model pair overrides the known-working parent combo, and an
  -- explicit per-call `model` overrides the definition (follow-ups never get here:
  -- a resumed child keeps the combo in its frontmatter).
  if header.model and header.model ~= "" then
    local p, m = header.model:match("^([^/]+)/(.+)$")
    if p then
      provider, model = p, m
    end
  end
  if override_provider then
    provider, model = override_provider, override_model
  end
  local allowed = vim.deepcopy(DEFAULT_SUBAGENT_TOOLS)
  if header.tools and header.tools ~= "" then
    allowed = {}
    local aliases = { grep = "search", find = "glob", webfetch = "fetch" }
    local known = {}
    for _, name in ipairs(ALLOWED_TOOLS) do
      known[name] = true
    end
    for name in header.tools:gmatch("[^,%s]+") do
      name = aliases[name] or name
      -- MCP tools are named mcp_<server>_<tool> and discovered at runtime,
      -- so they cannot be validated against the compiled-in list; trust the
      -- author of the agent definition to name a real one.
      if not known[name] and not name:match("^mcp_") then
        reply("error: agent definition " .. ev.agent .. " requires unsupported tool " .. name)
        return
      end
      allowed[#allowed + 1] = name
    end
  end
  local parent_path = vim.b[parent].yap_path
  local parent_name = paths.session_name(parent_path)
  local dir = paths.session_dir(vim.b[parent].yap_project_cwd or vim.fn.getcwd())
  local child_path
  repeat
    local random = vim.uv.random(3)
    local hex = string.format("%02x%02x%02x", random:byte(1, 3))
    child_path = paths.new_session_path(dir, parent_name .. "-" .. hex)
  until vim.fn.filereadable(child_path) == 0
  local ok, child = pcall(harness().new, {
    path = child_path,
    system = body,
    agent = ev.agent,
    provider = provider,
    model = model,
    tools = allowed,
    hidden = true,
  })
  if not ok then
    reply("error: cannot create subagent: " .. tostring(child))
    return
  end
  document.append_text(child, ev.task)
  vim.b[child].yap_subagent_parent = parent
  vim.b[child].yap_subagent_task = ev.task
  frontmatter.update(child, { subagent_parent = parent_path })
  require("harness.session").save(child)
  subagent_children[parent] = child
  frontmatter.record_subagent(parent, child_path)
  subagent_done[child] = subagent_result(parent, child, child_path, reply)
  harness().send(child)
end

--- Stop and wipe every child session when its parent is unloaded.
function M.close_children(parent)
  subagent_children[parent] = nil
  for _, child in ipairs(vim.api.nvim_list_bufs()) do
    if child ~= parent and vim.b[child].yap and vim.b[child].yap_subagent_parent == parent then
      -- Closing a child must not send a late result into a parent being
      -- closed; stop it before wiping its buffer.
      subagent_done[child] = nil
      harness().stop(child)
      if vim.api.nvim_buf_is_valid(child) then
        pcall(vim.api.nvim_buf_delete, child, { force = true })
      end
    end
  end
end

return M

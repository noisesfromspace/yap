-- Subagent orchestration: spawn a child session for a `subagent_request`
-- event, run it, and report its final answer back to the parent's serve
-- process. Also owns tearing down every child when a parent is unloaded.

local M = {}

local state = require("harness.state")
local frontmatter = require("harness.model.frontmatter")
local config = require("harness.config")
local paths = require("harness.path")
local document = require("harness.model.document")
local structure = require("harness.model.structure")

local function harness()
  return require("harness")
end

local subagent_children = state.subagent_children
local subagent_done = state.subagent_done
local errors = state.errors
local running = state.running
local servers = state.servers

local function subagent_result(parent, child, child_path, reply)
  return function(success)
    subagent_children[parent] = nil
    local result = "error: " .. (errors[child] or "subagent stopped without a result")
    if success then
      -- Reuse the transcript parser for headings and marker regions, including
      -- fences in tool output. Only the last assistant message is returned.
      local lines = vim.api.nvim_buf_get_lines(child, 0, -1, false)
      result = table.concat(structure.last_answer(lines), "\n")
      if result == "" then
        result = "error: subagent returned no final answer"
      end
    end
    reply("Session: [" .. child_path .. "](" .. child_path .. ")\n" .. result)
  end
end

--- Handle a `subagent_request` event: create a child session from an
--- agent-definition file.
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
  -- explicit per-call `model` overrides the definition.
  if header.model and header.model ~= "" then
    local p, m = config.parse_combo(header.model)
    if p then
      provider, model = p, m
    end
  end
  if override_provider then
    provider, model = override_provider, override_model
  end
  local allowed = ev.tools
  if type(allowed) ~= "table" or #allowed == 0 then
    reply("error: subagent requires a nonempty tools list chosen by the caller")
    return
  end
  local seen = {}
  for _, name in ipairs(allowed) do
    if type(name) ~= "string" or not name:match("^[%w_%-]+$") or name == "subagent" or seen[name] then
      reply("error: invalid subagent tool " .. tostring(name))
      return
    end
    seen[name] = true
  end
  local parent_path = vim.b[parent].yap_path
  local parent_name = paths.session_name(parent_path)
  local dir = paths.session_dir(vim.b[parent].yap_project_cwd or vim.fn.getcwd())
  local child_path
  repeat
    local random = vim.uv.random(3)
    local hex = string.format("%02x%02x%02x", random:byte(1, 3))
    child_path = paths.new_session_path(paths.child_session_dir(dir, parent_path), parent_name .. "-" .. hex)
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

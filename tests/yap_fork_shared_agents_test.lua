-- A fork retains links to existing agents, not copies of their files. Both
-- saved and open pickers must show those links under every referencing branch.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ model_groups = { agent = "mock/m1", flash = "" }})
local session = require("harness.session")
local fm = require("harness.model.frontmatter")

local function agent(parent, title)
  local child = yap.new({ agent = "audit", hidden = true })
  local path = vim.b[child].yap_path
  fm.update(child, { title = title, subagent_parent = vim.b[parent].yap_path })
  fm.record_subagent(parent, path)
  session.save(child)
  session.save(parent)
  return child, path
end

-- A fork made before any agents has no shared references. A subsequent
-- agent belongs only to the branch that ran it.
local empty_source = yap.new()
fm.update(empty_source, { title = "Before agents" })
local empty_path = vim.b[empty_source].yap_path
vim.api.nvim_set_current_buf(empty_source)
local empty_fork_path = assert(yap.fork("before-agents-fork"))
local empty_fork = vim.api.nvim_get_current_buf()
local _, new_agent_path = agent(empty_fork, "Only on fork")
local before = session.list("cwd")
local function below(rows, key, child, parent)
  for i, row in ipairs(rows) do
    if row[key] == parent then
      for j = i + 1, #rows do
        if rows[j].depth <= row.depth then
          break
        end
        if rows[j][key] == child and rows[j].depth == row.depth + 1 then
          return true
        end
      end
    end
  end
  return false
end
assert(below(before, "path", new_agent_path, empty_fork_path), "fork-only agent missing")
assert(not below(before, "path", new_agent_path, empty_path), "agent appeared on pre-fork source")

local root = yap.new()
fm.update(root, { title = "Original" })
local early, early_path = agent(root, "Early review")
local root_path = vim.b[root].yap_path
vim.api.nvim_set_current_buf(root)
local fork_path = assert(yap.fork("refactor-audit"))
local fork = vim.api.nvim_get_current_buf()
fm.update(fork, { title = "Refactor audit" })
session.save(fork)
local later, later_path = agent(fork, "Go safety")
local root_only, root_only_path = agent(root, "Fix review")
vim.api.nvim_set_current_buf(fork)
local leaf_path = assert(yap.fork("follow-up"))
local leaf = vim.api.nvim_get_current_buf()
fm.update(leaf, { title = "Follow-up" })
session.save(leaf)
local leaf_only, leaf_only_path = agent(leaf, "Lua UI review")

local function check(rows, key, label)
  local position = {}
  for i, row in ipairs(rows) do
    position[row[key]] = position[row[key]] or {}
    table.insert(position[row[key]], i)
  end
  local function inside(child, parent)
    for _, p in ipairs(position[parent] or {}) do
      local depth = rows[p].depth
      for i = p + 1, #rows do
        if rows[i].depth <= depth then
          break
        end
        if rows[i][key] == child and rows[i].depth == depth + 1 then
          return true
        end
      end
    end
    return false
  end
  assert(#(position[early] or position[early_path] or {}) == 3, label .. ": early link missing")
  assert(inside(early, root) or inside(early_path, root_path), label .. ": original missing early")
  assert(inside(early, fork) or inside(early_path, fork_path), label .. ": fork missing early")
  assert(inside(early, leaf) or inside(early_path, leaf_path), label .. ": nested fork missing early")
  assert(inside(later, fork) or inside(later_path, fork_path), label .. ": fork missing later")
  assert(inside(later, leaf) or inside(later_path, leaf_path), label .. ": nested fork missing later")
  assert(not inside(later, root) and not inside(later_path, root_path), label .. ": fork-only agent under original")
  assert(inside(root_only, root) or inside(root_only_path, root_path), label .. ": original missing later agent")
  assert(
    not inside(root_only, fork) and not inside(root_only_path, fork_path),
    label .. ": original-only agent under fork"
  )
  assert(inside(leaf_only, leaf) or inside(leaf_only_path, leaf_path), label .. ": leaf missing own agent")
  for _, row in ipairs(rows) do
    if row[key] == early or row[key] == early_path then
      assert(row.text:find("[shared: 3 branches]", 1, true), label .. ": shared label missing")
    end
  end
end

check(session.list("cwd"), "path", "saved")
local captured
local select = vim.ui.select
vim.ui.select = function(items, opts, callback)
  captured = { items = items, opts = opts, callback = callback }
end
yap.sessions()
local saved_rows = 0
for _, row in ipairs(captured.items) do
  if row.path == early_path then
    saved_rows = saved_rows + 1
    assert(
      captured.opts.format_item(row):find("^" .. yap.config.icons.idle .. " ") == 1,
      "shared saved rows should show the same open status"
    )
  end
end
assert(saved_rows == 3, "saved picker lost shared references")
yap.instances()
vim.ui.select = select
check(captured.items, "buf", "open")
local first, second
for _, row in ipairs(captured.items) do
  if row.buf == early then
    if first then
      second = row
    else
      first = row
    end
  end
end
assert(first and second and first ~= second and first.buf == second.buf, "shared picker rows must select one file")
captured.callback(second)
assert(vim.api.nvim_get_current_buf() == early, "selecting a shared row must open the shared session")

local state = require("harness.state")
state.stopped[early] = true
vim.api.nvim_set_current_buf(leaf)
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.waiting()
vim.ui.select = select
assert(captured and captured.items, "waiting picker missing")
local waiting_early = 0
for _, row in ipairs(captured.items) do
  if row.buf == early then
    waiting_early = waiting_early + 1
    assert(row.text:find("[shared: 3 branches]", 1, true), "waiting picker lost shared label")
  end
end
assert(waiting_early == 3, "waiting picker lost shared references")
state.stopped[early] = nil

-- Closing that session leaves three selectable saved references; the status
-- column stays aligned and the open picker omits all three appearances.
vim.api.nvim_buf_delete(early, { force = true })
check(session.list("cwd"), "path", "saved after close")
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.sessions()
for _, row in ipairs(captured.items) do
  if row.path == early_path then
    assert(captured.opts.format_item(row):sub(1, 3 + #row.text) == "   " .. row.text, "closed shared row shifted")
  end
end
captured = nil
vim.ui.select = function(items, opts)
  captured = { items = items, opts = opts }
end
yap.instances()
vim.ui.select = select
for _, row in ipairs(captured.items) do
  assert(row.buf ~= early, "closed shared agent in open picker")
end
print("OK fork_shared_agents")

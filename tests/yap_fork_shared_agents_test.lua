-- A subagent belongs to exactly the session that spawned it: recorded as a
-- single child->parent directory pointer (`subagent_parent`), never copied
-- into a fork. Both pickers nest a subagent under its one parent; a fork does
-- not inherit its source's agents, and a pre-fork agent stays under its
-- original parent only.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ model_groups = { agent = "mock/m1", flash = "" }})
local session = require("harness.session")
local fm = require("harness.model.frontmatter")

local function title(buf, text)
  local dir = vim.fn.fnamemodify(vim.b[buf].yap_path, ":h")
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. text .. ".md")
  session.save(buf)
end

local function agent(parent, text)
  local child = yap.new({ agent = "audit", hidden = true })
  title(child, text)
  fm.update(child, { subagent_parent = vim.fn.fnamemodify(vim.b[parent].yap_path, ":h") })
  session.save(child)
  return child, vim.b[child].yap_path
end

local select = vim.ui.select
local function capture(call)
  local captured
  vim.ui.select = function(items, opts, callback)
    captured = { items = items, opts = opts, callback = callback }
  end
  call()
  vim.ui.select = select
  return captured and captured.items or {}
end

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

-- Original -> fork -> leaf, with agents on three branches.
local root = yap.new()
title(root, "Original")
local early, early_path = agent(root, "Early review")
local root_path = vim.b[root].yap_path
vim.api.nvim_set_current_buf(root)
local fork_path = assert(yap.fork("refactor-audit"))
local fork = vim.api.nvim_get_current_buf()
title(fork, "Refactor audit")
session.save(fork)
fork_path = vim.b[fork].yap_path
local later, later_path = agent(fork, "Go safety")
local root_only, root_only_path = agent(root, "Fix review")
vim.api.nvim_set_current_buf(fork)
local leaf_path = assert(yap.fork("follow-up"))
local leaf = vim.api.nvim_get_current_buf()
title(leaf, "Follow-up")
session.save(leaf)
leaf_path = vim.b[leaf].yap_path
local leaf_only, leaf_only_path = agent(leaf, "Lua UI review")

local function check(rows, key, label)
  local n = function(buf, path)
    return key == "buf" and buf or path
  end
  local cases = {
    { child = n(early, early_path), parent = n(root, root_path), want = true, msg = "original missing early" },
    { child = n(early, early_path), parent = n(fork, fork_path), want = false, msg = "early inherited by fork" },
    { child = n(early, early_path), parent = n(leaf, leaf_path), want = false, msg = "early inherited by leaf" },
    { child = n(later, later_path), parent = n(fork, fork_path), want = true, msg = "fork missing later" },
    { child = n(later, later_path), parent = n(root, root_path), want = false, msg = "later under original" },
    { child = n(later, later_path), parent = n(leaf, leaf_path), want = false, msg = "later inherited by leaf" },
    { child = n(root_only, root_only_path), parent = n(root, root_path), want = true, msg = "original missing root_only" },
    { child = n(root_only, root_only_path), parent = n(fork, fork_path), want = false, msg = "root_only under fork" },
    { child = n(leaf_only, leaf_only_path), parent = n(leaf, leaf_path), want = true, msg = "leaf missing leaf_only" },
  }
  for _, c in ipairs(cases) do
    local got = below(rows, key, c.child, c.parent)
    if c.want then
      assert(got, label .. ": " .. c.msg)
    else
      assert(not got, label .. ": " .. c.msg)
    end
  end
  for _, row in ipairs(rows) do
    assert(not row.text:find("[shared:", 1, true), label .. ": unexpected shared label: " .. row.text)
  end
end

check(capture(function()
  yap.sessions("open")
end), "buf", "open")

check(session.list("cwd"), "path", "saved")

-- Selecting a subagent row opens its session.
local captured
vim.ui.select = function(items, opts, callback)
  captured = { items = items, opts = opts, callback = callback }
end
yap.sessions("open")
vim.ui.select = select
local early_row
for _, row in ipairs(captured.items) do
  if row.buf == early then
    early_row = row
  end
end
assert(early_row, "early agent row missing")
captured.callback(early_row)
assert(vim.api.nvim_get_current_buf() == early, "selecting an agent row must open its session")

-- Closing an agent's buffer removes it from the open picker; its saved file
-- remains discoverable under its still-open parent in saved history.
vim.api.nvim_buf_delete(early, { force = true })
for _, row in ipairs(capture(function()
  yap.sessions("open")
end)) do
  assert(row.buf ~= early, "closed agent in open picker")
end
check(session.list("cwd"), "path", "saved-after-agent-close")

-- Closing the parent hides its subagents from saved history, so an inactive
-- conversation's row stays lean.
vim.api.nvim_buf_delete(root, { force = true })
for _, row in ipairs(session.list("cwd")) do
  assert(row.path ~= early_path and row.path ~= root_only_path, "subagent shown under a closed parent: " .. row.path)
end
print("OK fork_shared_agents")

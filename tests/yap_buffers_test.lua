-- Listed-buffer labels are presentation only. The regular MiniPick source
-- must keep ordinary items and buffer-number selection intact.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
if vim.env.YAP_MINI_NVIM and vim.env.YAP_MINI_NVIM ~= "" then
  vim.opt.rtp:prepend(vim.env.YAP_MINI_NVIM)
end
local yap = require("harness")
local buffers = require("harness.session.buffers")
local state = require("harness.state")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }, nerd_font = false })

-- The session title is the transcript filename: rename the buffer to set it.
local function title(buf, text, description)
  local dir = vim.fn.fnamemodify(vim.b[buf].yap_path, ":h")
  local base = (text ~= "" and text) and (text .. ".md") or "session.md"
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. base)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  lines = vim.tbl_filter(function(line)
    return not line:match("^description:")
  end, lines)
  if description then
    table.insert(lines, 2, "description: " .. description)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

-- Status is a tag, not an icon: a picker filters on the label text, so
-- `[WAIT]` must be typeable to find the sessions awaiting a reply. Padding
-- follows the tag, so the tag itself stays contiguous for the query.
local function tag(word)
  local t = "[" .. word .. "]"
  return t .. string.rep(" ", 7 - #t)
end

local a = yap.new()
local path = vim.b[a].yap_path
title(a, "Pinned", "Generated")
assert(buffers.label(a) == tag("IDLE") .. "Generated", "description should win over the filename title")
assert(vim.b[a].yap_path == vim.fn.fnamemodify(path, ":h") .. "/Pinned.md", "filename title not recorded")
assert(vim.fn.filereadable(vim.b[a].yap_path) == 1, "real session file missing")
assert(vim.fn.expand("%:p:h") == vim.fn.fnamemodify(path, ":h"), "explorer directory is not the session directory")
local files = require("mini.files")
files.setup()
files.open(vim.b[a].yap_path) -- the user's '-' mapping
assert(files.get_explorer_state().anchor == vim.fn.fnamemodify(path, ":h"), "MiniFiles opened the wrong directory")
files.close()

-- Shared labels follow the current state, including approval precedence.
for _, key in ipairs({ "awaiting", "stopped", "errors", "running", "pending_approvals" }) do
  state[key][a] = key == "running" and {} or true
  local word = ({
    awaiting = "WAIT",
    stopped = "STOP",
    errors = "ERR",
    running = "RUN",
    pending_approvals = "APPR",
  })[key]
  assert(buffers.label(a) == tag(word) .. "Generated", "label state missing: " .. key)
end
for _, key in ipairs({ "awaiting", "stopped", "errors", "running", "pending_approvals" }) do
  state[key][a] = nil
end

local b = yap.new()
title(b, "Pinned")
-- Drop a's description so both labels use the same filename title.
local a_lines = vim.api.nvim_buf_get_lines(a, 0, -1, false)
a_lines = vim.tbl_filter(function(line)
  return not line:match("^description:")
end, a_lines)
vim.api.nvim_buf_set_lines(a, 0, -1, false, a_lines)
local la, lb = buffers.label(a), buffers.label(b)
assert(la ~= lb, "duplicate titles need distinct labels")
assert(la:find("Pinned", 1, true) and lb:find("Pinned", 1, true), "duplicates lost their title")
assert(la:match(tostring(a) .. "%D*$") and lb:match(tostring(b) .. "%D*$"), "duplicates need buffer-number suffixes")
title(b, "Other")
assert(buffers.label(a) == tag("IDLE") .. "Pinned", "unique title kept its suffix")
title(b, "", "Generated title")
assert(buffers.label(b) == tag("IDLE") .. "Generated title", "description fallback missing")
local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
lines = vim.tbl_filter(function(line)
  return not line:match("^description:")
end, lines)
vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
assert(
  buffers.label(b)
    == tag("IDLE") .. require("harness.path").session_name(vim.b[b].yap_path),
  "session directory fallback missing"
)

local child = yap.new({ agent = "scout", hidden = true })
assert(not vim.bo[child].buflisted, "subagent should be unlisted")
state.awaiting[child] = true
assert(yap.overview(a) == "", "subagent leaked into winbar overview")
state.awaiting[child] = nil

local file = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "return true" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))
local filebuf = vim.api.nvim_get_current_buf()
local term = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(term)
vim.fn.termopen({ "sh", "-c", "printf terminal" })
local man = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(man, "man://yap(1)")
vim.bo[man].buftype = "nofile"
vim.bo[man].filetype = "man"
for _, buf in ipairs({ filebuf, term, man }) do
  assert(buffers.label(buf) == nil, "non-Yap buffer received a Yap label")
end

local pick = require("mini.pick")
pick.setup()
local captured
local original_start = pick.start
pick.start = function(opts)
  captured = opts
  return opts
end
-- Baseline items from the regular picker, before Yap presentation.
pick.builtin.buffers()
local baseline = {}
for _, item in ipairs(captured.source.items) do
  baseline[item.bufnr] = item.text
end
captured = nil
yap.buffers()
assert(captured and captured.source, "buffer picker did not start")
local items = {}
for _, item in ipairs(captured.source.items) do
  items[item.bufnr] = item
end
for _, buf in ipairs({ a, b }) do
  assert(items[buf], "listed Yap buffer missing from mixed picker")
  assert(items[buf].text == buffers.label(buf), "picker disagrees with shared label API")
end
assert(not items[child], "unlisted subagent leaked into buffer picker")
-- Rendering gives every entry its filetype icon; a Yap session keeps its
-- status tag in the label and the markdown filetype icon on the left.
local display = vim.api.nvim_create_buf(false, true)
captured.source.show(display, { items[a], items[term], items[man], items[filebuf] }, {})
local shown = vim.api.nvim_buf_get_lines(display, 0, -1, false)
local has_icons, icons = pcall(require, "mini.icons")
local yap_icon = has_icons and icons.get("file", vim.api.nvim_buf_get_name(a)) or " "
assert(shown[1] == yap_icon .. " " .. buffers.label(a), "Yap entry missing its filetype icon")
-- A terminal resolves its shell by name (term://…/zsh -> the shell glyph),
-- not the generic terminal filetype, which has no icon of its own.
local term_icon = has_icons and icons.get("file", vim.api.nvim_buf_get_name(term)) or " "
assert(shown[2] == term_icon .. " " .. items[term].text, "terminal lost its shell icon")
vim.api.nvim_buf_delete(display, { force = true })
for _, buf in ipairs({ filebuf, term, man }) do
  assert(items[buf] and items[buf].text == baseline[buf], "ordinary picker item changed: " .. buf)
end

-- Choosing a synthetic label must switch by bufnr, never try to edit the label.
local choose = captured.source.choose or pick.default_choose
local name_before = vim.api.nvim_buf_get_name(a)
choose(items[a])
assert(vim.api.nvim_get_current_buf() == a, "picker did not select by buffer number")
assert(vim.api.nvim_buf_get_name(a) == name_before, "picker selection replaced the filename")
pick.start = original_start

-- Directly reopening a saved subagent must retain its unlisted status, too.
local child_path = vim.b[child].yap_path
vim.api.nvim_buf_delete(child, { force = true })
vim.cmd("edit " .. vim.fn.fnameescape(child_path))
local adopted_child = vim.api.nvim_get_current_buf()
assert(vim.b[adopted_child].yap_agent == "scout", "reopened subagent lost its role")
assert(not vim.bo[adopted_child].buflisted, "reopened subagent should remain unlisted")
vim.cmd("badd " .. vim.fn.fnameescape(child_path))
assert(not vim.bo[adopted_child].buflisted, "badd exposed an internal subagent")

print("OK buffers")

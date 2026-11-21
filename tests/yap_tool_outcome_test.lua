-- Tool-outcome badges and edit-size annotations on closed tool folds.
-- Pure state: the markers are written directly, no provider traffic.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local fold = require("harness.ui.fold")
local structure = require("harness.model.structure")

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant",
  "",
  '<!-- yap:tool {"id":"e","name":"edit","arguments":{"path":"f","edits":[]}} -->',
  "Successfully replaced 1 edit(s) in f.",
  "<!-- yap:ui -->",
  "```diff",
  "--- a/f",
  "+++ b/f",
  "@@ -1,2 +1,3 @@",
  "-old1",
  "-old2",
  "+new1",
  "+new2",
  "+new3",
  "```",
  "<!-- /yap:ui -->",
  "<!-- /yap:tool -->",
  "",
  '<!-- yap:tool {"id":"b","name":"bash","arguments":{"command":"x"}} -->',
  "```",
  "out",
  "[exit code 7]",
  "```",
  "<!-- /yap:tool -->",
  '<!-- yap:event {"type":"tool_outcome","outcome":"exit","code":7} -->',
  "",
  '<!-- yap:tool {"id":"r","name":"read","arguments":{"path":"/f"}} -->',
  "```",
  "content",
  "```",
  "<!-- /yap:tool -->",
  '<!-- yap:event {"type":"tool_outcome","outcome":"timeout"} -->',
  "",
  '<!-- yap:tool {"id":"x","name":"broken","arguments":{"command":"y"}} -->',
  "error: boom",
  "<!-- /yap:tool -->",
  '<!-- yap:event {"type":"tool_outcome","outcome":"error"} -->',
  "",
})

local function region_by_name(p, name)
  for _, r in ipairs(p.regions) do
    if r.kind == "tool" then
      local line = vim.api.nvim_buf_get_lines(buf, r.start - 1, r.start, false)[1] or ""
      if line:match('"name":%s*"([^"]+)"') == name then
        return r
      end
    end
  end
  return nil
end

local p = structure.parse(buf)

-- The three outcome markers parsed, keyed by their owning tool's start line.
assert(#p.tool_outcomes == 3, "outcomes: " .. #p.tool_outcomes)
local by_outcome = {}
for _, d in ipairs(p.tool_outcomes) do
  by_outcome[d.outcome] = d
end
assert(by_outcome.exit and by_outcome.exit.code == 7, vim.inspect(by_outcome.exit))
assert(by_outcome.timeout, "timeout outcome missing")
assert(by_outcome.error, "error outcome missing")

-- A nonzero exit badges its fold as a warning, and the marker folds into the
-- tool region.
local bash = region_by_name(p, "bash")
assert(bash and bash.fold_finish >= by_outcome.exit.line, "exit marker not folded into bash tool")
local bash_chunks = fold.text(bash.start, bash.fold_finish)
assert(type(bash_chunks) == "table", "bash outcome badge missing")
assert(bash_chunks[1][1] == "[exit 7] " and bash_chunks[1][2] == "DiagnosticWarn", vim.inspect(bash_chunks[1]))

-- A timeout is an error-severity badge.
local read = region_by_name(p, "read")
local read_chunks = fold.text(read.start, read.fold_finish)
assert(read_chunks[1][1] == "[Timed out] " and read_chunks[1][2] == "DiagnosticError", vim.inspect(read_chunks[1]))

-- A tool error is an error-severity badge.
local errored = region_by_name(p, "broken")
assert(errored, "broken region missing")
local error_chunks = fold.text(errored.start, errored.fold_finish)
assert(error_chunks[1][1] == "[Error] " and error_chunks[1][2] == "DiagnosticError", vim.inspect(error_chunks[1]))

-- An edit's display diff counts added/removed lines as colored chunks
-- (DiffAdd for additions, DiffDelete for removals).
local edit = region_by_name(p, "edit")
local edit_chunks = fold.text(edit.start, edit.finish)
assert(type(edit_chunks) == "table", "edit size should be colored chunks, not a badge")
assert(edit_chunks[1][1] == "▸ tool: edit" and edit_chunks[1][2] == "Folded", vim.inspect(edit_chunks))
local plus, slash, minus
for _, c in ipairs(edit_chunks) do
  if c[1] == "+3" then
    plus = c[2]
  elseif c[1] == "/" then
    slash = c[2]
  elseif c[1] == "-2" then
    minus = c[2]
  end
end
assert(plus == "DiffAdd" and minus == "DiffDelete", "edit size colors: " .. vim.inspect(edit_chunks))
assert(slash == "Comment", "diff separator must stay neutral: " .. vim.inspect(edit_chunks))

-- A :YapClear placeholder badges the tool fold `[Cleared]` (muted: the local
-- output is gone, but the audit log still has it).
local cleared_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(cleared_buf)
vim.api.nvim_buf_set_lines(cleared_buf, 0, -1, false, {
  '<!-- yap:tool {"id":"c","name":"read","arguments":{"path":"/f"}} -->',
  "[output cleared — full output in the audit log: ~/audit:12]",
  "<!-- /yap:tool -->",
  "",
})
local cp = structure.parse(cleared_buf)
assert(cp.regions[1].cleared == true, "cleared flag not parsed")
local cleared_chunks = fold.text(cp.regions[1].start, cp.regions[1].finish)
assert(type(cleared_chunks) == "table", "cleared badge missing")
assert(cleared_chunks[1][1] == "[Cleared] " and cleared_chunks[1][2] == "Comment", vim.inspect(cleared_chunks[1]))

print("OK tool outcome and edit size")

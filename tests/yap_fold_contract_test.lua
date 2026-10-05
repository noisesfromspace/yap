-- Behavioural contract: identities survive edits, intent survives streaming,
-- native commands agree with Tab, and separate windows remain independent.
vim.opt.rtp:prepend(vim.fn.getcwd())
local fold = require("harness.fold")
local keys = require("harness").config.keymaps
local api, fn = vim.api, vim.fn
local function make(lines, view)
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "hide"
  api.nvim_set_current_buf(b)
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  fold.setup_buffer(b, keys)
  fold.set_view_level(view or 2)
  return b
end
local function append(b, text)
  require("harness.document").append_text(b, text)
end
local function native(line, command)
  api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("normal! " .. command)
end
local function tool(id)
  return '<!-- yap:tool {"id":"' .. id .. '","name":"bash"} -->'
end
local closed = "<!-- /yap:tool -->"
local fixture = { "# @assistant", "", tool("a"), "one", closed, "", tool("b"), "two", closed, "" }

-- Mixing native commands and Yap commands must not resurrect old intent.
local b = make(fixture)
fold.toggle(3)
native(3, "zc")
append(b, "<!-- yap:thinking\nnew\n-->\n")
assert(fn.foldclosed(3) == 3, "native close after Tab was undone")
native(7, "zo")
append(b, tool("c") .. "\nthree\n" .. closed .. "\n")
assert(fn.foldclosed(7) == -1, "native open lost on unrelated append")
assert(fn.foldclosed(13) == 13, "new tool inherited sibling open")

-- A live range can grow through arbitrary chunk boundaries. Both command
-- paths preserve opens and closes; the first complete opener is folded.
for _, view in ipairs({ 1, 2 }) do
  for _, use_tab in ipairs({ false, true }) do
    b = make({ "# @user", "q", view == 1 and "# @assistant" or tool("live") }, view)
    assert(fn.foldclosed(3) == 3, "single-line opener flashed open")
    if use_tab then fold.toggle(3) else native(3, "zo") end
    for _, chunk in ipairs({ "\nfirst", " more", "\nsecond", "\nthird" }) do
      append(b, chunk)
      assert(fn.foldclosed(3) == -1, "growing open fold reclosed")
    end
    if use_tab then fold.toggle(3) else native(3, "zc") end
    append(b, "\nfourth")
    assert(fn.foldclosed(3) == 3, "growing closed fold reopened")
  end
end

-- Moving the text cannot transfer B's open to A at B's former line.
b = make(fixture)
fold.toggle(7)
api.nvim_buf_set_lines(b, 0, 0, false, { "prefix", "prefix", "prefix", "prefix" })
fold.after_append(b)
assert(fn.foldclosed(7) == 7, "stale B pin opened A")
assert(fn.foldclosed(11) == -1, "B lost its open after insertion")
api.nvim_buf_set_lines(b, 0, 4, false, {})
fold.after_append(b)
assert(fn.foldclosed(3) == 3 and fn.foldclosed(7) == -1, "deletion lost anchored state")

-- Real user edit/undo: deleted anchors do not attach to replacements, and
-- undo restores the original identity and choice. Break the API undo block.
b = make(fixture)
fold.toggle(3)
vim.cmd("let &ul = &ul")
api.nvim_buf_set_lines(b, 2, 5, false, {})
fold.after_append(b)
assert(fn.foldclosed(4) == 4, "deleted pin transferred to the next tool")
vim.cmd("undo")
fold.after_append(b)
assert(fn.foldclosed(3) == -1 and fn.foldclosed(7) == 7, "undo lost original intent")
vim.cmd("redo")
fold.after_append(b)
assert(fn.foldclosed(4) == 4, "redo resurrected deleted pin")

-- Ordinary edits reconcile without a stream callback.
b = make({ "# @assistant", "prose", "" })
api.nvim_buf_set_lines(b, -1, -1, false, { tool("typed"), "output", closed })
assert(vim.wait(100, function() return fn.foldclosed(4) == 4 end), "user edits did not reconcile")

-- Returning is synchronous and retains choices while defaults govern new
-- hidden output. No wait() before inspecting the returning window.
b = make(fixture)
local w1 = api.nvim_get_current_win()
fold.toggle(3)
local other = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(other)
append(b, tool("hidden") .. "\noutput\n" .. closed .. "\n")
api.nvim_set_current_buf(b)
assert(fn.foldclosed(3) == -1, "return lost open")
assert(fn.foldclosed(7) == 7 and fn.foldclosed(10) == 10, "hidden output returned unfolded")

-- New splits use the selected view's defaults, not copied native opens.
vim.cmd("vsplit")
local w2 = api.nvim_get_current_win()
assert(fn.foldclosed(3) == 3, "new split inherited open override")
fold.toggle(7)
append(b, "<!-- yap:thinking\nmore\n-->\n")
assert(fn.foldclosed(3) == 3 and fn.foldclosed(7) == -1, "W1 intent leaked into W2")
api.nvim_set_current_win(w1)
assert(fn.foldclosed(3) == -1 and fn.foldclosed(7) == 7, "W2 intent leaked into W1")
fold.set_view_level(1)
api.nvim_set_current_win(w2)
assert(fold.level() == 2 and fn.foldclosed(7) == -1, "view reset affected another window")
api.nvim_win_close(w2, true)

-- Native removal cannot leave the installed-fold cache pretending to exist.
b = make(fixture)
vim.cmd("normal! zE")
fold.reconcile(b)
assert(fn.foldclosed(3) == 3 and fn.foldclosed(7) == 7, "missing native folds not repaired")
native(7, "zo")
native(3, "zd")
fold.reconcile(b)
assert(fn.foldclosed(7) == -1, "repair lost a surviving native open")

-- Appending to an existing user message must not rewrite historical anchors.
b = make(fixture)
append(b, "# @user\n\nquestion")
fold.toggle(3)
require("harness.document").append_message(b, "user", { "continued" })
assert(fn.foldclosed(3) == -1 and fn.foldclosed(7) == 7, "message append discarded history intent")

-- Stream fragments that could still be structural are withheld, never
-- painted as prose. Ordinary prose and unterminated final text stay lossless.
b = make({ "# @assistant", "" })
local document = require("harness.document")
local pending, rendered = "", ""
for _, part in ipairs({ "<", "!-- ya", "p:thinking", "\n", "thought", "\n-->\n", "regular prose" }) do
  local ready
  ready, pending = document.split_stream_tail(b, pending .. part)
  rendered = rendered .. ready
  append(b, ready)
  if part == "p:thinking" then assert(rendered == "", "partial opener was exposed") end
end
assert(pending == "" and rendered == "<!-- yap:thinking\nthought\n-->\nregular prose", "stream text changed")
local ready, held = document.split_stream_tail(b, "\n#")
assert(ready == "\n" and held == "#", "partial heading not held for final flush")

-- An explicit unload/reload reinitializes folds, rather than disabling
-- future streaming updates. A hidden (not unloaded) session retains intent.
local unloaded = make(fixture)
local other_buffer = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(other_buffer)
vim.bo[unloaded].modified = false
vim.cmd("bunload " .. unloaded)
api.nvim_set_current_buf(unloaded)
api.nvim_buf_set_lines(unloaded, 0, -1, false, fixture)
fold.after_append(unloaded)
assert(fn.foldclosed(3) == 3, "unloaded session no longer reconciles")

-- Malformed tools stop at the next message instead of overlapping it; system
-- examples do not create detail folds nested inside the system fold.
b = make({ "# @system", "<!-- yap:thinking", "example", "-->", "# @assistant", tool("broken"), "output", "# @user", "q", "# @assistant", tool("next"), "r", closed })
assert(fn.foldlevel(2) == 1, "system detail created nesting")
assert(fn.foldclosedend(6) == 7, "unfinished tool swallowed next message")
assert(fn.foldclosed(11) == 11 and fn.foldlevel(11) == 1, "detail ranges overlapped")

-- Reading position must not be dragged by a fold recreated below it.
b = make(fixture)
api.nvim_win_set_cursor(0, { 2, 0 })
local before = fn.winsaveview()
append(b, "<!-- yap:thinking\nmore\n")
local after = fn.winsaveview()
assert(before.lnum == after.lnum and before.col == after.col and before.topline == after.topline,
  "stream changed reading position")
print("OK fold_contract")

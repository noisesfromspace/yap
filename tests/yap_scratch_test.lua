local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })
local buf = yap.new()
local notes_file = require("harness.path").notes_path(buf)
assert(vim.fn.filereadable(notes_file) == 1, "new session did not create notes.md")
local chat_win = vim.api.nvim_get_current_win()

-- <leader>j is bound in the session buffer
yap.scratch_toggle()
local scratch_win = vim.api.nvim_get_current_win()
assert(scratch_win ~= chat_win, "scratch did not open a new window")
local scratch = vim.api.nvim_get_current_buf()
assert(scratch ~= buf, "scratch is the session buffer")
assert(vim.bo[scratch].buftype == "", "scratch buffer is not file-backed")
assert(vim.bo[scratch].buflisted == false, "scratch buffer should be unlisted")
assert(vim.bo[scratch].filetype == "markdown", "scratch should be markdown")
assert(vim.wo.spell == true, "scratch should enable spell")
assert(vim.fn.maparg("<C-CR>", "n", false, true).buffer == 1, "scratch has no template picker")
assert(vim.fn.bufname(scratch) == notes_file, "scratch has wrong file path")
assert(vim.fn.filereadable(notes_file) == 1, "opening scratch did not create notes.md")
assert(vim.fn.getfperm(notes_file) == "rw-------", "scratch is not private")
assert(vim.b[scratch].yap == nil, "notes.md was adopted as a transcript")
local initial = { "# @steer", "", "# @queue" }
assert(table.concat(vim.fn.readfile(notes_file), "\n") == table.concat(initial, "\n"), "new scratch headings were not saved")
assert(not vim.bo[scratch].modified, "new scratch should be clean")
assert(vim.wait(3000, function()
  return #vim.lsp.get_clients({ bufnr = scratch, name = "yap" }) > 0
end), "scratch has no yap LSP client")
local client = vim.lsp.get_clients({ bufnr = scratch, name = "yap" })[1]
assert(vim.wait(3000, function() return client.initialized end), "scratch LSP did not initialize")
vim.api.nvim_buf_set_lines(scratch, -1, -1, false, { "see @fla" })
local res = client:request_sync("textDocument/completion", {
  textDocument = { uri = vim.uri_from_bufnr(scratch) },
  position = { line = 3, character = 8 },
}, 3000, scratch)
assert(res and res.result and res.result.items and #res.result.items > 0, "scratch @file completion is empty")
vim.api.nvim_buf_set_lines(scratch, 3, -1, false, {})

-- A generated description changes the session label, not the scratch path.
local frontmatter = require("harness.model.frontmatter")
frontmatter.update(buf, { description = "Fix the picker" })
require("harness.session").save(buf)
assert(vim.fn.bufname(scratch) == notes_file, "session description renamed the scratch")
assert(vim.wo.winfixheight == true, "scratch window is not fixed height")
assert(vim.api.nvim_win_get_height(0) == 12, "scratch window height is not 12")
assert(
  vim.api.nvim_win_get_position(scratch_win)[1] > vim.api.nvim_win_get_position(chat_win)[1],
  "scratch window is not below the chat"
)
assert(vim.wo.winbar == "", "scratch window inherited the yap winbar")
assert(vim.b[scratch].yap == nil, "scratch scratch was adopted as a yap session")
assert(
  not require("harness.state").sessions[scratch],
  "scratch scratch registered as a session for the winbar rollup"
)
assert(
  vim.fn.maparg("<C-s>", "n", false, true).desc == "yap: send scratch",
  "scratch <C-s> must dispatch to the owner session, not send the scratch itself"
)
assert(vim.wo.foldmethod == "expr", "scratch sections are not foldable")
assert(vim.wo.foldenable, "scratch folding is disabled")

-- Each control section has its own fold; closing one leaves the others open.
vim.api.nvim_win_call(scratch_win, function()
  assert(vim.fn.foldlevel(1) == 1, "steer heading has no fold")
  assert(vim.fn.foldlevel(3) == 1, "queue heading has no fold")
  vim.api.nvim_win_set_cursor(scratch_win, { 1, 0 })
  vim.cmd("normal! zc")
  assert(vim.fn.foldclosed(1) == 1, "steer section did not fold")
  assert(vim.fn.foldtextresult(1):find("# @steer", 1, true), "closed fold lost its section label")
  assert(vim.fn.foldclosed(3) == -1, "folding steer also closed queue")
  vim.cmd("normal! zo")
end)

-- Native :write saves the scratch at its own path.
local saved = { "# @steer", "next task", "", "# @queue", "task one", "task two" }
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, saved)
assert(vim.bo[scratch].modified, "editing scratch should mark it modified")
vim.cmd("write")
assert(not vim.bo[scratch].modified, ":write did not clear modified")
assert(table.concat(vim.fn.readfile(notes_file), "\n") == table.concat(saved, "\n"), "saved scratch mismatch")
vim.api.nvim_buf_set_lines(scratch, -1, -1, false, { "unsaved draft" })
assert(vim.bo[scratch].modified, "unsaved draft should remain modified")
assert(not table.concat(vim.fn.readfile(notes_file), "\n"):find("unsaved draft", 1, true), "draft autosaved")

-- content survives the toggle
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
assert(#vim.fn.win_findbuf(scratch) == 0, "scratch did not close")
assert(vim.api.nvim_buf_is_valid(scratch), "scratch was wiped on close")
assert(vim.api.nvim_buf_get_lines(scratch, 0, 1, false)[1] == "# @steer", "scratch content not preserved")

-- reopening reuses the same buffer and content
yap.scratch_toggle()
assert(#vim.fn.win_findbuf(scratch) == 1, "scratch did not reopen")
assert(vim.api.nvim_get_current_buf() == scratch, "scratch did not focus on reopen")
assert(vim.api.nvim_buf_get_lines(scratch, 0, 1, false)[1] == "# @steer", "scratch content lost on reopen")
assert(vim.api.nvim_buf_get_lines(scratch, -2, -1, false)[1] == "unsaved draft", "toggle lost unsaved draft")
assert(vim.bo[scratch].modified, "toggle cleared modified state")
vim.api.nvim_buf_set_lines(scratch, -2, -1, false, {})
vim.cmd("write")
assert(vim.fn.maparg("<leader>j", "n", false, true).buffer == 1, "scratch has no <leader>j map")

-- A recreated scratch reloads the saved file rather than starting fresh.
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
vim.api.nvim_buf_delete(scratch, { force = true })
vim.b[buf].yap_scratch = nil
-- An ordinary :edit can list the file before Yap opens its scratch drawer.
local listed = vim.fn.bufadd(notes_file)
vim.fn.bufload(listed)
vim.bo[listed].buflisted = true
yap.scratch_toggle()
local reloaded = vim.api.nvim_get_current_buf()
assert(reloaded == listed and vim.bo[reloaded].buflisted, "opening scratch unlisted an existing notes buffer")
assert(reloaded ~= scratch, "scratch did not recreate")
local reloaded_text = table.concat(vim.api.nvim_buf_get_lines(reloaded, 0, -1, false), "\n")
assert(reloaded_text == table.concat(saved, "\n"), "recreated scratch did not load saved notes")
assert(vim.fn.filereadable(notes_file) == 1, "recreating scratch lost notes.md")
vim.bo[reloaded].buflisted = false -- restore the original navigation assumptions below

-- A drawer is anchored below the chat's own window: when the chat is one
-- pane of a vertical split the drawer stays in that column (not full-width),
-- and closing it refocuses the chat.
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
vim.cmd("vsplit")
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
assert(vim.api.nvim_get_current_buf() == reloaded, "scratch did not reopen beside the vertical split")
assert(
  vim.api.nvim_win_get_width(0) == vim.api.nvim_win_get_width(chat_win),
  "scratch drawer is not under the chat column: " .. vim.api.nvim_win_get_width(0) .. " vs " .. vim.api.nvim_win_get_width(chat_win)
)
assert(
  vim.api.nvim_win_get_position(0)[2] == vim.api.nvim_win_get_position(chat_win)[2],
  "scratch drawer is not aligned with the chat column"
)
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle()
assert(#vim.fn.win_findbuf(reloaded) == 0, "scratch did not close from the vertical split")
assert(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == buf, "closing scratch did not refocus chat")

-- <leader>t in the notes opens the session's tail viewer: the scratch's owner
-- is the session buffer, so the live toggle targets the session, not the
-- notes file.
yap.scratch_toggle()
assert(vim.api.nvim_get_current_buf() == reloaded, "scratch did not reopen for the live map")
assert(vim.fn.maparg("<leader>t", "n", false, true).buffer == 1, "scratch has no <leader>t map")
local leader = vim.g.mapleader
if leader == nil or leader == "" then
  leader = "\\"
end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(leader .. "l", true, false, true), "mtx", false)
local tail = vim.api.nvim_get_current_buf()
assert(vim.fn.bufname(tail):match("^Yap Tail: "), "scratch <leader>t did not open the tail viewer")

-- A session closed with :bd keeps its scratch. The scratch outlives the
-- session (bufhidden = hide) with its draft, so reopening the session must
-- re-attach that scratch instead of opening a second, empty one — which also
-- collided on the shared display name and aborted the toggle.
local session_path = vim.api.nvim_buf_get_name(buf)
vim.api.nvim_buf_set_lines(reloaded, 0, -1, false, { "# @steer", "", "# @queue", "survives :bd" })
vim.api.nvim_set_current_win(chat_win)
yap.scratch_toggle() -- close the scratch window; the buffer and its draft survive
assert(#vim.fn.win_findbuf(reloaded) == 0, "scratch did not close")
vim.cmd("bdelete " .. buf)
assert(not vim.api.nvim_buf_is_loaded(buf), ":bd did not unload the session")
assert(
  vim.api.nvim_buf_get_lines(reloaded, 3, 4, false)[1] == "survives :bd",
  "closing the session lost the scratch draft"
)
vim.fn.bufload(buf)
vim.api.nvim_win_set_buf(chat_win, buf)
assert(vim.b[buf].yap_scratch == nil, ":bd should drop the buffer-local tie")
yap.scratch_toggle(buf)
assert(
  vim.api.nvim_get_current_buf() == reloaded,
  "reopening the session did not re-attach its scratch: " .. vim.api.nvim_get_current_buf()
)
local scratchs = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.b[b].yap_scratch_notes and vim.b[b].yap_owner == buf then
    scratchs[#scratchs + 1] = b
  end
end
assert(#scratchs == 1, "reopening the session created a second scratch: " .. vim.inspect(scratchs))
assert(session_path == vim.api.nvim_buf_get_name(buf), ":bd orphaned the transcript path")

print("OK scratch")

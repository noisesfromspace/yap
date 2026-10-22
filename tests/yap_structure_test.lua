-- One document reader. Every consumer of the session markdown (the request
-- messages, :YapClear, :YapCompact's history delete, the end-of-turn repair and
-- the picker labels) derives from harness.model.structure, so a construct that
-- *looks* like structure but is quoted inside a fence or a marker region is
-- never mistaken for one.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local document = require("harness.model.document")
local structure = require("harness.model.structure")
local maintain = require("harness.session.maintain")
local session = require("harness.session")

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local buf = yap.new()

-- 1. Appending follows the structural trailing heading, not a fenced one.
-- A `# @user` quoted inside an assistant's fenced block must not become the
-- message new text lands in.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "q",
  "",
  "# @assistant",
  "",
  "```markdown",
  "# @user",
  "```",
  "",
})
assert(document.trailing_role(buf) == "assistant", "fenced heading became the trailing role")
document.append_message(buf, "user", { "next question" })
local headings = structure.parse(buf).headings
assert(#headings == 3, "expected a fresh user heading, got " .. vim.inspect(headings))
assert(headings[3].role == "user", "appended text landed under the wrong role")
assert(text(buf):find("# @user\n\nnext question", 1, true), "appended text misplaced: " .. text(buf))

-- 2. An unclosed tool region is bounded at the next message instead of
-- swallowing the rest of the conversation (R-buffer-only-state).
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @user",
  "",
  "first question",
  "",
  "# @assistant",
  "",
  '<!-- yap:tool {"id":"c1","name":"bash","arguments":{"command":"x"}} -->',
  "partial output",
  "",
  "# @user",
  "",
  "second question",
  "",
})
local msgs = document.parse_buffer(buf)
assert(#msgs == 3, "unclosed tool region swallowed the next message: " .. vim.inspect(msgs))
assert(msgs[2].role == "assistant" and msgs[2].content:find("partial output", 1, true), "partial output lost")
assert(msgs[3].role == "user" and msgs[3].content == "second question", "second question lost")

-- 3. :YapClear only rewrites real tool results. A `<!-- yap:tool` line quoted
-- inside a fenced result is content and must survive.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant",
  "",
  "```markdown",
  '<!-- yap:tool {"id":"fake","name":"x","arguments":{}} -->',
  "```",
  "",
  '<!-- yap:tool {"id":"real1","name":"bash","arguments":{}} -->',
  "first result body",
  "<!-- /yap:tool -->",
  "",
  '<!-- yap:tool {"id":"real2","name":"bash","arguments":{}} -->',
  "second result body",
  "<!-- /yap:tool -->",
  "",
  "# @user",
  "",
})
maintain.clear(buf, 1)
local cleared = text(buf)
assert(cleared:find('"id":"fake"', 1, true), "fenced fake tool region was cleared")
assert(not cleared:find("first result body", 1, true), "oldest real result not cleared")
assert(cleared:find("second result body", 1, true), "kept region was cleared")

-- 4. :YapCompact's history delete keeps the last *real* assistant message. A
-- `# @assistant` quoted inside a fenced block after the summary is content.
local seeded = yap.new()
local fm_end = require("harness.model.frontmatter").end_line(seeded)
local head = vim.api.nvim_buf_get_lines(seeded, 0, fm_end, false)
vim.api.nvim_buf_set_lines(
  buf,
  0,
  -1,
  false,
  vim.list_extend(head, {
    "",
    "# @system",
    "",
    "sys",
    "",
    "# @user",
    "",
    "old question",
    "",
    "# @assistant",
    "",
    "old answer",
    "",
    "# @assistant",
    "",
    "the summary",
    "",
    "```markdown",
    "# @assistant",
    "```",
    "",
    "# @user",
    "",
  })
)
vim.api.nvim_buf_delete(seeded, { force = true })
maintain.delete(buf)
local kept = text(buf)
assert(kept:find("the summary", 1, true), "summary was deleted: " .. kept)
assert(not kept:find("old answer", 1, true), "superseded history survived: " .. kept)
assert(kept:find("# @system\n\nsys", 1, true), "system message lost: " .. kept)
assert(kept:find("title:", 1, true), "frontmatter lost: " .. kept)

-- 5. End-of-turn repair reads the structural state, so a marker quoted inside a
-- fence is not an open region.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant",
  "",
  "```",
  "<!-- yap:tool",
  "```",
  "",
  "answer",
  "",
})
assert(
  next(structure.open_tail(buf)) == nil,
  "fenced marker reported as dangling: " .. vim.inspect(structure.open_tail(buf))
)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant",
  "",
  '<!-- yap:tool {"id":"c9","name":"bash","arguments":{}} -->',
  "streamed output",
  "",
})
local open = structure.open_tail(buf)
assert(open.tool and not open.comment, "open tool region not detected: " .. vim.inspect(open))
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @assistant",
  "",
  "<!-- yap:tool",
  "{",
  '  "id": "c10",',
  '  "name": "bash"',
  "}",
})
open = structure.open_tail(buf)
assert(open.tool and open.comment, "open multi-line header not detected: " .. vim.inspect(open))

-- 6. Picker labels read the structural message body, so a fenced heading cannot
-- supply a subagent's task line.
local slice = {
  "# @system",
  "",
  "sys",
  "",
  "# @user",
  "",
  "the real task",
  "",
  "# @assistant",
  "",
  "```",
  "# @user",
  "fake",
  "```",
  "",
}
assert(session.task(slice) == "the real task", "fenced heading leaked into the task label")

print("OK structure")

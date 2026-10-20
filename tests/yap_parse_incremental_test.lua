-- Regression: the incremental tail-append parser (structure.extend) must
-- produce exactly the same headings/regions/count as a full rescan, across
-- the structural cases a streamed reply walks through — thinking blocks,
-- multi-line tool headers, fences, and headings — and it must fall back to a
-- full rescan (and stay correct) when a middle edit invalidates the tail-only
-- assumption.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.ui.fold")
local document = require("harness.model.document")
local structure = require("harness.model.structure")

local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "",
  "sys",
  "",
  "# @user",
  "",
  "q",
  "",
  "# @assistant",
  "",
  '<!-- yap:tool {"id":"t1","name":"bash","arguments":{}} -->',
  "result one",
  "<!-- /yap:tool -->",
  "",
})
fold.setup_buffer(buf)
fold.set_view_level(2)

-- Deep-compare the incremental (cached) result against a forced full rescan.
local function assert_consistent(label)
  local extended = vim.deepcopy(structure.parse(buf))
  structure.clear(buf)
  local full = structure.parse(buf)
  assert(
    vim.deep_equal(extended, full),
    label .. ": extend != parse\n  extended="
      .. vim.inspect(extended)
      .. "\n  full="
      .. vim.inspect(full)
  )
end

assert_consistent("baseline")

-- Streamed chunks that exercise each structural path. Several are split so a
-- single append leaves an opener/header mid-way (exactly what streaming does).
local chunks = {
  "<!-- yap:thinking\nlet me think\nabout it\n-->\n\n",
  '<!-- yap:tool {"id":"t2",',
  '"name":"read","arguments":{"path":"/tmp/x"}} -->\n',
  "```\nfenced body\n```\n",
  "# @user\n\nnext question\n",
}
for _, chunk in ipairs(chunks) do
  document.append_text(buf, chunk)
  assert_consistent("after chunk " .. vim.inspect(chunk:sub(1, 20)))
end

-- A middle edit invalidates the tail-only assumption: the next append must
-- rescan fully and remain correct (no shifted-line corruption).
vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "edited in the middle" })
document.append_text(buf, "tail text\n")
assert_consistent("after middle edit")

print("OK parse_incremental")

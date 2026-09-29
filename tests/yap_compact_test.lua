local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.mkdir(tmp .. "/templates", "p")
vim.fn.mkdir(tmp .. "/skills", "p")
local function w(path, text)
  local f = io.open(path, "w")
  f:write(text)
  f:close()
end
w(tmp .. "/templates/compact.md", "Summarize everything.\n")

yap.setup({
  bin = ROOT .. "/yap",
  templates_dir = tmp .. "/templates",
  skills_dir = tmp .. "/skills",
  skills_intro = false,
})

-- ── compact_delete: deterministic, no mock ──────────────────────────────
do
  local buf = yap.new({ provider = "mock", model = "m1" })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ui
  for i, l in ipairs(lines) do
    if l:match("^# @user%s*$") then
      ui = i
      break
    end
  end
  vim.api.nvim_buf_set_lines(buf, ui - 1, -1, false, {
    "# @user", "", "original question", "",
    "# @assistant", "", "original answer", "",
    "# @user", "", "Summarize everything.", "",
    "# @assistant", "", "The summary.", "",
    "# @user", "",
  })
  yap.compact_delete(buf)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(text:match("^%-%-%-"), "frontmatter lost: " .. text)
  assert(text:match("# @system"), "system block lost: " .. text)
  assert(text:match("You are a helpful coding assistant"), "system content lost: " .. text)
  assert(text:match("The summary%."), "summary lost: " .. text)
  assert(text:match("# @user"), "trailing user prompt lost: " .. text)
  assert(not text:match("original question"), "old history not deleted: " .. text)
  assert(not text:match("Summarize everything%."), "compact prompt not deleted: " .. text)
  local roles = {}
  for _, m in ipairs(yap.parse_buffer(buf)) do
    roles[#roles + 1] = m.role
  end
  assert(vim.deep_equal(roles, { "system", "assistant" }), "parse roles: " .. vim.inspect(roles))
end

-- ── :YapCompact end-to-end: insert, send, offer, delete ────────────────
do
  local buf = yap.new({ provider = "mock", model = "m1" })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ui
  for i, l in ipairs(lines) do
    if l:match("^# @user%s*$") then
      ui = i
      break
    end
  end
  vim.api.nvim_buf_set_lines(buf, ui - 1, -1, false, {
    "# @user", "", "original question", "",
    "# @assistant", "", "original answer", "",
  })

  local offered
  vim.ui.select = function(items, opts, cb)
    offered = { items = items, prompt = opts.prompt }
    cb(items[1]) -- "Delete history"
  end

  yap.compact()
  local done = vim.wait(8000, function()
    local t = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return t:match("The slow answer arrives in parts%.") ~= nil and not t:match("original question")
  end, 100)
  assert(done, "compact flow did not complete")
  assert(offered and offered.items[1] == "Delete history", "delete offer not shown")
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(text:match("The slow answer arrives in parts%."), "summary lost: " .. text)
  assert(text:match("# @system"), "system lost: " .. text)
  assert(not text:match("Summarize everything%."), "compact prompt not deleted: " .. text)
  assert(text:match("# @user"), "trailing user prompt lost: " .. text)
end

print("OK compact")

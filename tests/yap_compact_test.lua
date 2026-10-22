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
    "# @user",
    "",
    "original question",
    "",
    "# @assistant",
    "",
    "original answer",
    "",
    "# @user",
    "",
    "Summarize everything.",
    "",
    "# @assistant",
    "",
    "The summary.",
    "",
    "# @user",
    "",
  })
  require("harness.session.maintain").delete(buf)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(text:match("^%-%-%-"), "frontmatter lost: " .. text)
  assert(text:match("# @system"), "system block lost: " .. text)
  -- System content may come from a user AGENTS.md or the default; require it to be non-empty,
  -- not a specific string.
  do
    local lines = vim.split(text, "\n", { plain = true })
    local sys, next_head
    for i, l in ipairs(lines) do
      if l:match("^# @system%s*$") then
        sys = i
        break
      end
    end
    if sys then
      for j = sys + 1, #lines do
        if lines[j]:match("^# @%a+%s*$") then
          next_head = j - 1
          break
        end
      end
      next_head = next_head or #lines
      local nonempty = false
      for k = sys + 1, next_head do
        if lines[k] and not lines[k]:match("^%s*$") then
          nonempty = true
          break
        end
      end
      assert(nonempty, "system content lost: " .. text)
    else
      assert(false, "system block lost: " .. text)
    end
  end
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
    "# @user",
    "",
    "original question",
    "",
    "# @assistant",
    "",
    "original answer",
    "",
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

-- ── compact always adds the Tree-sitter/frontmatter-safe output constraint ──
do
  local buf = yap.new({ provider = "mock", model = "m1" })
  local original_send = yap.send
  local sent_text
  yap.send = function()
    sent_text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  yap.compact()
  yap.send = original_send
  assert(
    sent_text and sent_text:match("Do not use the colon character anywhere in the summary"),
    "compact output constraint missing: " .. tostring(sent_text)
  )
  assert(sent_text:match("Avoid YAML/frontmatter delimiters"), "frontmatter-safe constraint missing")
end

print("OK compact")

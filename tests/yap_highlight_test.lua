-- Treesitter highlight policy: yap always drops the inline (markdown_inline)
-- pass, keeping block-level colours, with no configuration knob. The injection
-- mutation is exercised only where a markdown parser is available; the guard
-- paths (invalid buffer, no parser) are parser-free.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local highlight = require("harness.session.highlight")

yap.setup({ bin = ROOT .. "/yap" })

local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @system", "", "sys", "", "# @user", "" })

-- A fresh buffer drops the inline injection; the flag that marks it applied
-- survives re-application without error.
highlight.apply(buf)

-- If the markdown parser exists, the inline child must be gone and the
-- injection query re-pointed; otherwise the guard must have been a silent
-- no-op.
local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
if ok and parser and parser._children then
  assert(parser._children.markdown_inline == nil, "markdown_inline child not dropped")
  assert(parser._injection_query ~= nil, "injection query not set")
  assert(parser._injection_query ~= vim.treesitter.query.get("markdown", "injections"), "injection query not replaced")
  -- The fenced-code injection must be marked combined so all fences of a
  -- language collapse into one tree (the grammar-free observable of the
  -- O(#fences)-per-scroll fix).
  assert(parser._injection_query.has_combined_injections == true, "fenced-code injection not combined")

  -- Injected trees must stay constant in the number of tool markers: the
  -- highlighter walks every injected tree on each viewport change, so a tree
  -- per marker (`html_block` -> html -> `comment`) made scrolling O(#tool
  -- calls).
  local many = {}
  for i = 1, 200 do
    many[#many + 1] = "# @assistant"
    many[#many + 1] = '<!-- yap:tool {"id":"c' .. i .. '","name":"bash"} -->'
    many[#many + 1] = "```diff"
    many[#many + 1] = "- old " .. i
    many[#many + 1] = "+ new " .. i
    many[#many + 1] = "```"
    many[#many + 1] = "<!-- /yap:tool -->"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, many)
  parser._processed_injection_region = nil
  parser:parse(true)
  local trees, langs = 0, {}
  parser:for_each_tree(function(_, tree)
    trees = trees + 1
    langs[tree:lang()] = true
  end)
  assert(
    trees <= 3,
    "injected trees scale with tool markers: " .. trees .. " trees " .. vim.inspect(vim.tbl_keys(langs))
  )
end

-- Re-applying is a safe no-op (drop_inline is idempotent).
highlight.apply(buf)
highlight.apply(buf)

-- The policy is size-independent: growing the session does not change it.
local big = {}
for i = 1, 20 do
  big[i] = "line " .. i
end
vim.api.nvim_buf_set_lines(buf, -1, -1, false, big)
highlight.apply(buf)

print("OK highlight")

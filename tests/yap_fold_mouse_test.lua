local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})
local fold = require("harness.ui.fold")

local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "instructions",
  "",
  "# @user",
  "hi",
  "",
  "# @assistant",
  "<!-- yap:thinking",
  "hmm",
  "-->",
  "",
  '<!-- yap:tool {"id":"b1","name":"bash","arguments":{}} -->',
  "result",
  "<!-- /yap:tool -->",
  "",
})
fold.setup_buffer(buf) -- default view 2: thinking/tool regions folded
local win = vim.api.nvim_get_current_win()

local think, tool = 8, 12
assert(vim.fn.foldclosed(think) == think, "thinking folded by default")
assert(vim.fn.foldclosed(tool) == tool, "tool folded by default")

-- The <LeftMouse> mapping is an expr map bound to this buffer.
local mouse_map = vim.fn.maparg("<LeftMouse>", "n", false, true)
assert(
  mouse_map and mouse_map.expr == 1 and mouse_map.buffer == 1,
  "expr <LeftMouse> map missing: " .. vim.inspect(mouse_map)
)

local real_getmousepos = vim.fn.getmousepos
local function click(line)
  vim.fn.getmousepos = function()
    return { winid = win, line = line, column = 1, screenrow = 0, screencol = 0 }
  end
  return fold.mouse_left()
end

-- A click on open content defers to native handling and changes nothing.
assert(click(4) == "<LeftMouse>", "non-fold click should defer to native")
assert(vim.fn.foldclosed(think) == think and vim.fn.foldclosed(tool) == tool, "non-fold click changed folds")

-- A click on a closed fold opens just that fold and consumes the click.
assert(click(think) == "", "fold click should open, not defer")
assert(vim.fn.foldclosed(think) == -1, "click did not open the thinking fold")
assert(vim.fn.foldclosed(tool) == tool, "click opened an unrelated fold")

-- The open is a persistent pin, like <Tab>: an append re-applies and keeps it.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "# @user", "", "next", "" })
fold.after_append(buf, { "# @user", "" })
assert(vim.fn.foldclosed(think) == -1, "append lost the click-opened pin")

-- The other fold opens independently. The mouse path must NOT reconcile:
-- reconcile runs `:normal zE`, which is forbidden inside an expr map (E523),
-- so the click must open from the already-reconciled projection.
local real_reconcile = fold.reconcile
fold.reconcile = function()
  error("mouse open must not reconcile")
end
assert(click(tool) == "", "second fold click should open")
assert(vim.fn.foldclosed(tool) == -1, "click did not open the tool fold")
fold.reconcile = real_reconcile
assert(click(4) == "<LeftMouse>", "open-content click should defer")

vim.fn.getmousepos = real_getmousepos
print("OK fold_mouse")

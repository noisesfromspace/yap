local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.fold")

local buf = yap.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system", "", "You are helpful.", "",
  "# @user", "", "Question here.", "",
  "# @assistant", "",
  "<!-- yap:thinking", "let me think", "about this", "-->", "",
  "Answer text.", "",
  "<!-- yap:tool", "{", '  "id": "w1",', '  "name": "write",', '  "arguments": {}', "}", "-->", "",
  "Wrote the file.", "",
  "<!-- yap:ui", "+x", "-->", "",
  "<!-- /yap:tool -->", "",
  "Done.", "",
  '<!-- yap:tool {"id":"b1","name":"bash","arguments":{}} -->',
  "ok result",
  "<!-- /yap:tool -->", "",
})
fold.setup_buffer(buf)

-- foldexpr: regions are level-3 folds inside the assistant block
local opener = 11 -- <!-- yap:thinking
assert(vim.fn.foldlevel(opener) == 3, "thinking opener level: " .. vim.fn.foldlevel(opener))
assert(vim.fn.foldlevel(12) == 3, "thinking content level: " .. vim.fn.foldlevel(12))
assert(vim.fn.foldlevel(14) == 3, "thinking closer inside fold: " .. vim.fn.foldlevel(14))
assert(vim.fn.foldlevel(16) == 2, "answer text stays level 2: " .. vim.fn.foldlevel(16))
-- the WHOLE tool region is one fold: header, result and ui included
local tool = 18
assert(vim.fn.foldlevel(tool) == 3, "tool opener level: " .. vim.fn.foldlevel(tool))
assert(vim.fn.foldlevel(tool + 7) == 3, "blank inside region level: " .. vim.fn.foldlevel(tool + 7))
assert(vim.fn.foldlevel(tool + 8) == 3, "tool result inside region fold: " .. vim.fn.foldlevel(tool + 8))
local ui = 28
assert(vim.fn.foldlevel(ui) == 3, "ui opener is region content: " .. vim.fn.foldlevel(ui))
assert(vim.fn.foldlevel(ui + 4) == 3, "/yap:tool closer inside fold: " .. vim.fn.foldlevel(ui + 4))
assert(vim.fn.foldlevel(ui + 6) == 2, "text after region stays level 2: " .. vim.fn.foldlevel(ui + 6))
-- single-line header folds the same way
local single = 36
assert(vim.fn.foldlevel(single) == 3, "single-line header level: " .. vim.fn.foldlevel(single))
assert(vim.fn.foldlevel(single + 1) == 3, "result after single-line header: " .. vim.fn.foldlevel(single + 1))
assert(vim.fn.foldlevel(single + 2) == 3, "closer after single-line header: " .. vim.fn.foldlevel(single + 2))
assert(vim.fn.foldlevel(single + 3) == 2, "blank after region level: " .. vim.fn.foldlevel(single + 3))

-- default state (view 1): only user prompts open
assert(vim.fn.foldclosed(1) == 1, "system block not folded by default")
assert(vim.fn.foldclosed(9) == 9, "assistant block not folded by default")
assert(vim.fn.foldclosed(5) == -1, "user block not open by default")
assert(fold.level() == 1, "default view is 1")

-- view 2: messages open (system prompt stays folded), thinking and
-- both tool regions folded
fold.set_view_level(2)
assert(vim.fn.foldclosed(1) == 1, "view 2 opens the system prompt")
assert(vim.fn.foldclosed(9) == -1, "view 2 does not open assistant block")
assert(vim.fn.foldclosed(opener) == opener, "view 2 does not fold thinking")
assert(vim.fn.foldclosed(tool) == tool, "view 2 does not fold tool region")
assert(vim.fn.foldclosed(tool + 8) == tool, "result not folded with tool region")
assert(vim.fn.foldclosed(ui) == tool, "ui not folded with tool region")
assert(vim.fn.foldclosed(single) == single, "view 2 does not fold single-line tool region")
assert(vim.fn.foldclosed(single + 1) == single, "single-line result not folded with region")
assert(fold.level() == 2, "view 2 reports level 2")
assert(fold.text(opener, 14) == "▸ yap:thinking (4 lines)", "foldtext: " .. fold.text(opener, 14))
assert(fold.text(tool, 32) == "▸ tool: write (15 lines)", "foldtext: " .. fold.text(tool, 32))
assert(fold.text(single, 38) == "▸ tool: bash (3 lines)", "foldtext: " .. fold.text(single, 38))

-- view 3 unfolds everything but the system prompt, deterministically
fold.set_view_level(3)
assert(vim.fn.foldclosed(opener) == -1, "view 3 opens thinking")
assert(vim.fn.foldclosed(tool) == -1, "view 3 opens tool region")
assert(vim.fn.foldclosed(1) == 1, "view 3 opens the system prompt")
assert(fold.level() == 3, "view 3 reports level 3")

-- view 2 from mixed state: close thinking only, open the tool fold, reapply
vim.cmd(("silent! %dfoldclose"):format(opener))
vim.cmd(("silent! %dfoldopen"):format(tool))
fold.set_view_level(2)
assert(vim.fn.foldclosed(opener) == opener, "view 2 refolds thinking")
assert(vim.fn.foldclosed(tool) == tool, "view 2 refolds tool region")
assert(vim.fn.foldclosed(single) == single, "view 2 refolds single-line tool region")

-- view 1 hides the whole assistant block including its regions
fold.set_view_level(1)
assert(vim.fn.foldclosed(9) == 9, "view 1 folds assistant")
assert(vim.fn.foldclosed(5) == -1, "view 1 keeps user open")
assert(vim.fn.foldlevel(opener) == 3, "level-3 fold under folded block still level 3")

-- fold state is STATIC between view keypresses: manually open a region
-- with za, then type a new message — nothing may move
fold.set_view_level(2)
vim.cmd(("silent! %dfoldopen"):format(tool))
assert(vim.fn.foldclosed(tool) == -1, "precondition: tool region opened manually")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "# @user", "", "next question", "continued" })
assert(vim.fn.foldclosed(tool) == -1, "typing closed a manually opened fold")
assert(vim.fn.foldclosed(opener) == opener, "typing opened the thinking fold")
assert(vim.fn.foldclosed(single) == single, "typing opened the single-line tool fold")
-- only pressing the view key AGAIN resets to the view
fold.set_view_level(2)
assert(vim.fn.foldclosed(tool) == tool, "reapplied view 2 does not refold")

-- winbar shows the applied view next to the model name
fold.set_view_level(2)
local bar = yap.winbar(buf)
assert(bar:find("Ⓕ2", 1, true), "winbar missing fold level: " .. bar)
assert(bar:find("in", 1, true) == nil, "winbar unexpectedly shows usage: " .. bar)
fold.set_view_level(3)
assert(yap.winbar(buf):find("Ⓕ3", 1, true), "winbar not updated to view 3: " .. yap.winbar(buf))
print("OK")

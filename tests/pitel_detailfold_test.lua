local ROOT = vim.env.PITEL_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local pitel = require("harness")
local fold = require("harness.fold")

local buf = pitel.new()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system", "", "You are helpful.", "",
  "# @user", "", "Question here.", "",
  "# @assistant", "",
  "<!-- pitel:thinking", "let me think", "about this", "-->", "",
  "Answer text.", "",
  "<!-- pitel:tool", "{", '  "id": "w1",', '  "name": "write",', '  "arguments": {}', "}", "-->", "",
  "Wrote the file.", "",
  "<!-- pitel:ui", "+x", "-->", "",
  "<!-- /pitel:tool -->", "",
  "Done.", "",
  '<!-- pitel:tool {"id":"b1","name":"bash","arguments":{}} -->',
  "ok result",
  "<!-- /pitel:tool -->", "",
})
fold.setup_buffer(buf)

-- foldexpr: regions are level-2 folds inside the assistant block
local opener = 11 -- <!-- pitel:thinking
assert(vim.fn.foldlevel(opener) == 2, "thinking opener level: " .. vim.fn.foldlevel(opener))
assert(vim.fn.foldlevel(12) == 2, "thinking content level: " .. vim.fn.foldlevel(12))
assert(vim.fn.foldlevel(14) == 2, "thinking closer inside fold: " .. vim.fn.foldlevel(14))
assert(vim.fn.foldlevel(16) == 1, "answer text stays level 1: " .. vim.fn.foldlevel(16))
-- the WHOLE tool region is one fold: header, result and ui included
local tool = 18
assert(vim.fn.foldlevel(tool) == 2, "tool opener level: " .. vim.fn.foldlevel(tool))
assert(vim.fn.foldlevel(tool + 7) == 2, "blank inside region level: " .. vim.fn.foldlevel(tool + 7))
assert(vim.fn.foldlevel(tool + 8) == 2, "tool result inside region fold: " .. vim.fn.foldlevel(tool + 8))
local ui = 28
assert(vim.fn.foldlevel(ui) == 2, "ui opener is region content: " .. vim.fn.foldlevel(ui))
assert(vim.fn.foldlevel(ui + 4) == 2, "/pitel:tool closer inside fold: " .. vim.fn.foldlevel(ui + 4))
assert(vim.fn.foldlevel(ui + 6) == 1, "text after region stays level 1: " .. vim.fn.foldlevel(ui + 6))
-- single-line header folds the same way
local single = 36
assert(vim.fn.foldlevel(single) == 2, "single-line header level: " .. vim.fn.foldlevel(single))
assert(vim.fn.foldlevel(single + 1) == 2, "result after single-line header: " .. vim.fn.foldlevel(single + 1))
assert(vim.fn.foldlevel(single + 2) == 2, "closer after single-line header: " .. vim.fn.foldlevel(single + 2))
assert(vim.fn.foldlevel(single + 3) == 1, "blank after region level: " .. vim.fn.foldlevel(single + 3))

-- default state (view 1): only user prompts open
assert(vim.fn.foldclosed(9) == 9, "assistant block not folded by default")
assert(vim.fn.foldclosed(5) == -1, "user block not open by default")
assert(fold.level() == 1, "default view is 1")

-- view 2: messages open, thinking and both tool regions folded
fold.set_view_level(2)
assert(vim.fn.foldclosed(9) == -1, "view 2 does not open assistant block")
assert(vim.fn.foldclosed(opener) == opener, "view 2 does not fold thinking")
assert(vim.fn.foldclosed(tool) == tool, "view 2 does not fold tool region")
assert(vim.fn.foldclosed(tool + 8) == tool, "result not folded with tool region")
assert(vim.fn.foldclosed(ui) == tool, "ui not folded with tool region")
assert(vim.fn.foldclosed(single) == single, "view 2 does not fold single-line tool region")
assert(vim.fn.foldclosed(single + 1) == single, "single-line result not folded with region")
assert(fold.level() == 2, "view 2 reports level 2")
assert(fold.text(opener, 14) == "▸ pitel:thinking (4 lines)", "foldtext: " .. fold.text(opener, 14))
assert(fold.text(tool, 32) == "▸ tool: write (15 lines)", "foldtext: " .. fold.text(tool, 32))
assert(fold.text(single, 38) == "▸ tool: bash (3 lines)", "foldtext: " .. fold.text(single, 38))

-- view 3 unfolds everything, deterministically
fold.set_view_level(3)
assert(vim.fn.foldclosed(opener) == -1, "view 3 opens thinking")
assert(vim.fn.foldclosed(tool) == -1, "view 3 opens tool region")
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
assert(vim.fn.foldlevel(opener) == 2, "level-2 fold under folded block still level 2")

-- winbar shows the applied view next to the model name
fold.set_view_level(2)
local bar = pitel.winbar(buf)
assert(bar:find("Ⓕ2", 1, true), "winbar missing fold level: " .. bar)
assert(bar:find("in", 1, true) == nil, "winbar unexpectedly shows usage: " .. bar)
fold.set_view_level(3)
assert(pitel.winbar(buf):find("Ⓕ3", 1, true), "winbar not updated to view 3: " .. pitel.winbar(buf))
print("OK")

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
})
fold.setup_buffer(buf)

-- foldexpr: regions are level-2 folds inside the assistant block
local opener = 11 -- <!-- pitel:thinking
assert(vim.fn.foldlevel(opener) == 2, "thinking opener level: " .. vim.fn.foldlevel(opener))
assert(vim.fn.foldlevel(12) == 2, "thinking content level: " .. vim.fn.foldlevel(12))
assert(vim.fn.foldlevel(14) == 2, "thinking closer inside fold: " .. vim.fn.foldlevel(14))
assert(vim.fn.foldlevel(16) == 1, "answer text stays level 1: " .. vim.fn.foldlevel(16))
local tool = 18
assert(vim.fn.foldlevel(tool) == 2, "tool opener level: " .. vim.fn.foldlevel(tool))
assert(vim.fn.foldlevel(tool + 7) == 1, "tool result stays level 1: " .. vim.fn.foldlevel(tool + 7))
local ui = 28
assert(vim.fn.foldlevel(ui) == 2, "ui opener level: " .. vim.fn.foldlevel(ui))
assert(vim.fn.foldlevel(ui + 4) == 1, "/pitel:tool closer level 1: " .. vim.fn.foldlevel(ui + 4))

-- default state (view 2): thinking, tool and ui folds closed, messages open
assert(vim.fn.foldclosed(opener) == opener, "thinking not closed by default")
assert(vim.fn.foldclosed(tool) == tool, "tool header not closed by default")
assert(vim.fn.foldclosed(ui) == ui, "ui region not closed by default")
assert(vim.fn.foldclosed(9) == -1, "assistant block folded by default")
assert(fold.level() == 2, "view 2 reports level 2")
assert(fold.text(opener, 14) == "▸ pitel:thinking (4 lines)", "foldtext: " .. fold.text(opener, 14))

-- view 3 unfolds everything, deterministically
fold.set_view_level(3)
assert(vim.fn.foldclosed(opener) == -1, "view 3 opens thinking")
assert(vim.fn.foldclosed(tool) == -1, "view 3 opens tool header")
assert(fold.level() == 0, "view 3 reports level 0")

-- view 2 from mixed state: close thinking only, then reapply
vim.cmd(("silent! %dfoldclose"):format(opener))
vim.cmd(("silent! %dfoldopen"):format(tool))
fold.set_view_level(2)
assert(vim.fn.foldclosed(opener) == opener, "view 2 refolds thinking")
assert(vim.fn.foldclosed(tool) == tool, "view 2 refolds tool header")
assert(vim.fn.foldclosed(ui) == ui, "view 2 refolds ui")

-- view 1 hides the whole assistant block including its regions
fold.set_view_level(1)
assert(vim.fn.foldclosed(9) == 9, "view 1 folds assistant")
assert(vim.fn.foldclosed(6) == -1, "view 1 keeps user open")
assert(vim.fn.foldlevel(opener) == 2, "level-2 fold under folded block still level 2")

-- winbar shows the fold level next to the model name
fold.set_view_level(2)
local bar = pitel.winbar(buf)
assert(bar:find("Ⓕ2", 1, true), "winbar missing fold level: " .. bar)
assert(bar:find("in", 1, true) == nil, "winbar unexpectedly shows usage: " .. bar)
fold.set_view_level(3)
assert(pitel.winbar(buf):find("Ⓕ0", 1, true), "winbar not updated to level 0: " .. pitel.winbar(buf))
print("OK")

local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local fold = require("harness.ui.fold")

-- The winbar assertions below read the model from the buffer, so pin a
-- short combo: the default (anthropic/claude-sonnet-5-5) is long enough to
-- push the model island out of the center section in an 80-column window.
local buf = yap.new({ provider = "mock", model = "m1" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "# @system",
  "",
  "You are helpful.",
  "",
  "# @user",
  "",
  "Question here.",
  "",
  "# @assistant",
  "",
  "<!-- yap:thinking",
  "let me think",
  "about this",
  "-->",
  "",
  "Answer text.",
  "",
  "<!-- yap:tool",
  "{",
  '  "id": "w1",',
  '  "name": "write",',
  '  "arguments": {}',
  "}",
  "-->",
  "",
  "Wrote the file.",
  "",
  "<!-- yap:ui -->",
  "+x",
  "<!-- /yap:ui -->",
  "",
  "<!-- /yap:tool -->",
  "",
  "Done.",
  "",
  '<!-- yap:tool {"id":"b1","name":"bash","arguments":{}} -->',
  "ok result",
  "<!-- /yap:tool -->",
  "",
})
fold.setup_buffer(buf)

-- The whole tool region is ONE fold (header, result, ui, closer); a
-- thinking block is its own fold; message prose stays unfolded.
local fc = vim.fn.foldclosed
local opener = 11 -- <!-- yap:thinking
assert(fc(opener) == opener, "thinking not folded: " .. fc(opener))
assert(fc(12) == opener, "thinking content outside fold: " .. fc(12))
assert(fc(14) == opener, "thinking closer outside fold: " .. fc(14))
assert(fc(16) == -1, "answer text should stay unfolded: " .. fc(16))
local tool = 18
assert(fc(tool) == tool, "tool not folded: " .. fc(tool))
assert(fc(tool + 7) == tool, "blank inside region outside fold: " .. fc(tool + 7))
assert(fc(tool + 8) == tool, "tool result outside fold: " .. fc(tool + 8))
local ui = 28
assert(fc(ui) == tool, "ui opener outside region fold: " .. fc(ui))
assert(fc(ui + 4) == tool, "/yap:tool closer outside fold: " .. fc(ui + 4))
assert(fc(ui + 6) == -1, "text after region should be unfolded: " .. fc(ui + 6))
-- single-line header folds the same way
local single = 36
assert(fc(single) == single, "single-line tool not folded: " .. fc(single))
assert(fc(single + 1) == single, "single-line result outside fold: " .. fc(single + 1))
assert(fc(single + 2) == single, "single-line closer outside fold: " .. fc(single + 2))
assert(fc(single + 3) == -1, "blank after region should be unfolded: " .. fc(single + 3))

-- default state (view 2): conversation open, display regions folded
assert(vim.fn.foldclosed(1) == 1, "system block not folded by default")
assert(vim.fn.foldclosed(9) == -1, "assistant block not open by default")
assert(vim.fn.foldclosed(5) == -1, "user block not open by default")
assert(vim.fn.foldclosed(opener) == opener, "thinking not folded by default")
assert(vim.fn.foldclosed(tool) == tool, "tool region not folded by default")
assert(fold.level() == 2, "default view is 2")

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
assert(fold.text(opener, 14) == "▸ yap: thinking (4 lines)", "foldtext: " .. fold.text(opener, 14))
assert(fold.text(tool, 32) == "▸ tool: write (15 lines)", "foldtext: " .. fold.text(tool, 32))
assert(fold.text(single, 38) == "▸ tool: bash (3 lines)", "foldtext: " .. fold.text(single, 38))

-- view 3 unfolds everything including the system prompt, deterministically
fold.set_view_level(3)
assert(vim.fn.foldclosed(opener) == -1, "view 3 opens thinking")
assert(vim.fn.foldclosed(tool) == -1, "view 3 opens tool region")
assert(vim.fn.foldclosed(1) == -1, "view 3 unfolds the system prompt")
assert(fold.level() == 3, "view 3 reports level 3")

-- view 2 from mixed state: close thinking only, open the tool fold, reapply
vim.cmd(("silent! %dfoldclose"):format(opener))
vim.cmd(("silent! %dfoldopen"):format(tool))
fold.set_view_level(2)
assert(vim.fn.foldclosed(opener) == opener, "view 2 refolds thinking")
assert(vim.fn.foldclosed(tool) == tool, "view 2 refolds tool region")
assert(vim.fn.foldclosed(single) == single, "view 2 refolds single-line tool region")

-- view 1 folds assistant messages, including the newest one
fold.set_view_level(1)
assert(vim.fn.foldclosed(9) == 9, "view 1 folds last assistant")
assert(vim.fn.foldclosed(5) == -1, "view 1 keeps user open")
assert(vim.fn.foldclosed(opener) == 9, "thinking is inside the folded assistant block")

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

-- The model island sits alone in the center of the winbar; the fold view
-- is no longer shown there.
fold.set_view_level(2)
local state = require("harness.state")
state.last_turn[buf] = { prompt = 50, context_window = 100 }
state.running[buf] = {}
state.live[buf] = { since = os.time() - 3, name = "bash" }
local bar = yap.winbar(buf)
local left, center, right = bar:match("^(.-)%%=(.-)%%=(.*)$")
assert(left and center and right, "winbar missing centered section: " .. bar)
local provider, model = require("harness.config").current_combo(buf)
local combo = provider .. "/" .. model
assert(not left:find(combo, 1, true) and not right:find(combo, 1, true), "model outside center: " .. bar)
local rendered_center = vim.api.nvim_eval_statusline(center, { winid = 0, use_winbar = true, maxwidth = 200 }).str
assert(rendered_center:find(" " .. combo .. " ", 1, true), "model island missing in center: " .. rendered_center)
assert(not rendered_center:find("󰘖", 1, true), "fold island should be gone: " .. rendered_center)
assert(right:find("50%%", 1, true), "winbar missing gauge: " .. right)
-- With usage present in a narrow window, the center yields to the right.
vim.b[buf].yap_usage = { prompt = 1200, completion = 100, cost = 0.002 }
bar = yap.winbar(buf)
assert(not bar:find("mock/m1", 1, true), "center should yield to usage: " .. bar)
right = assert(bar:match("%%=(.*)$"))
assert(right:find("1.3k", 1, true) and right:find("50%%", 1, true), "right cluster lost metrics: " .. right)
vim.b[buf].yap_usage = nil
state.running[buf], state.live[buf] = nil, nil
fold.set_view_level(3)
assert(not yap.winbar(buf):find("󰘖", 1, true), "fold view leaked into winbar: " .. yap.winbar(buf))
print("OK")

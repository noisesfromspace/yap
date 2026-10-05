#!/usr/bin/env python3
"""Attached-UI fold contract. Requires Python msgpack and nvim on PATH.

Run: python3 tests/yap_fold_ui_test.py
Only scratch buffers are used; no providers, session files or user config.
"""
import json
import os
from pathlib import Path
import select
import subprocess
import time

import msgpack

ROOT = Path(__file__).resolve().parent.parent


class UI:
    def __init__(self):
        self.process = subprocess.Popen(
            ["nvim", "--embed", "-u", "NONE", "-i", "NONE", "-n"],
            cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        )
        self.decoder = msgpack.Unpacker(raw=False)
        self.serial = 0
        self.grid = []
        self.frames = []
        self.call("nvim_ui_attach", [100, 35, {"ext_linegrid": True}])

    def redraw(self, events):
        for name, *args in events:
            for arg in args:
                if name == "grid_resize" and arg[0] == 1:
                    self.grid = [[" "] * arg[1] for _ in range(arg[2])]
                elif name == "grid_clear" and arg[0] == 1:
                    self.grid = [[" "] * len(row) for row in self.grid]
                elif name == "grid_line" and arg[0] == 1:
                    _, row, col, cells, *_ = arg
                    for cell in cells:
                        for _ in range(cell[2] if len(cell) > 2 else 1):
                            self.grid[row][col] = cell[0]
                            col += 1
                elif name == "grid_scroll" and arg[0] == 1:
                    _, top, bot, left, right, rows, cols = arg
                    assert cols == 0, "unexpected horizontal scrolling"
                    before = [r[:] for r in self.grid]
                    for row in range(top, bot):
                        self.grid[row][left:right] = (
                            before[row + rows][left:right]
                            if top <= row + rows < bot else [" "] * (right - left)
                        )
                elif name == "flush":
                    # A grid_line is only a partial update; flush is a frame.
                    self.frames.append("\n".join("".join(row) for row in self.grid))

    def call(self, method, args):
        self.serial += 1
        serial = self.serial
        self.process.stdin.write(msgpack.packb([0, serial, method, args], use_bin_type=True))
        self.process.stdin.flush()
        deadline = time.monotonic() + 10
        while True:
            for message in self.decoder:
                if message[0] == 2 and message[1] == "redraw":
                    self.redraw(message[2])
                elif message[0] == 1 and message[1] == serial:
                    assert message[2] is None, message[2]
                    return message[3]
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.process.stdout], [], [], remaining)[0], "RPC timeout"
            data = os.read(self.process.stdout.fileno(), 65536)
            assert data, "Neovim exited before RPC response"
            self.decoder.feed(data)

    def lua(self, source):
        return self.call("nvim_exec_lua", [source, []])

    def check(self, source, hidden=(), visible=()):
        self.frames = []
        self.lua(source + "\nvim.cmd('redraw!')")
        # Drain pending redraw notifications using another ordered RPC.
        self.lua("return true")
        assert self.frames, "test did not observe a rendered frame"
        for frame in self.frames:
            for text in hidden:
                assert text not in frame, f"Unfolded frame exposed {text!r}:\n{frame}"
        for text in visible:
            assert text in self.frames[-1], f"Final frame lacks {text!r}:\n{self.frames[-1]}"

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=5)


ui = UI()
try:
    ui.lua(r'''
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.showmode = false
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.o.cmdheight = 1
vim.o.scrolloff = 0
fold = require("harness.fold")
document = require("harness.document")
keys = setmetatable({ toggle_fold = "<Tab>" }, { __index = function() return "" end })
function fresh(view)
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# @assistant", "", "" })
  fold.setup_buffer(buf, keys)
  fold.set_view_level(view or 2)
  vim.api.nvim_win_set_cursor(0, {1, 0})
end
function append(text) document.append_text(buf, text) end
function tab(line)
  vim.api.nvim_win_set_cursor(0, {line, 0})
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "mtx", false)
end
fresh()
''')
    ui.check('append(\'<!-- yap:tool {"id":"a","name":"bash"} -->\')',
             hidden=('<!-- yap:tool',), visible=('tool: bash',))
    ui.check('append("\\nCLOSED_A")', hidden=('CLOSED_A', '<!-- yap:tool'), visible=('tool: bash',))
    ui.check('append("\\nCLOSED_A_MORE")', hidden=('CLOSED_A', 'CLOSED_A_MORE'))
    ui.check('tab(3)', visible=('CLOSED_A', 'CLOSED_A_MORE'))
    ui.check('append("\\nOPEN_A_GROWTH\\n<!-- /yap:tool -->\\n")', visible=('OPEN_A_GROWTH',))
    ui.check('append(\'<!-- yap:tool {"id":"b","name":"bash"} -->\\nCLOSED_B\\n<!-- /yap:tool -->\\n\')',
             hidden=('CLOSED_B',), visible=('OPEN_A_GROWTH',))
    ui.check(r'''
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(other)
append('<!-- yap:tool {"id":"c","name":"bash"} -->\nHIDDEN_C\n<!-- /yap:tool -->\n')
vim.api.nvim_set_current_buf(buf)
''', hidden=('CLOSED_B', 'HIDDEN_C'), visible=('OPEN_A_GROWTH',))
    # View 1 is also closed from its first frame and supports native opening.
    ui.check('fresh(1); append("summary\\nVIEW_ONE_HIDDEN")', hidden=('VIEW_ONE_HIDDEN',))
    ui.check('vim.api.nvim_win_set_cursor(0,{1,0}); vim.cmd("normal zo")', visible=('VIEW_ONE_HIDDEN',))
    ui.check('append("\\nVIEW_ONE_GROWTH")', visible=('VIEW_ONE_HIDDEN', 'VIEW_ONE_GROWTH'))
    # The same prefix splitting used by the real stdout flush prevents an
    # incomplete marker from painting as ordinary prose on earlier frames.
    ui.lua('fresh(); pending = ""')
    for part in ('<', '!-- ya', 'p:thinking', '\n', 'PREFIX_HIDDEN', '\n-->\n'):
        ui.check(
            'local ready; ready,pending=document.split_stream_tail(buf,pending .. '
            + json.dumps(part) + '); append(ready)',
            hidden=('<!', 'PREFIX_HIDDEN'),
        )
    print("OK fold_ui: closed arrivals/growth never painted open; open growth and hidden return preserved")
finally:
    ui.close()

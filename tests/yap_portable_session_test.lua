-- A session transcript can live anywhere: a yap-shaped markdown file outside
-- the sessions root is adopted on open, keeps its audit log and assets in a
-- central data directory (recorded in frontmatter as `data_dir`), and does not
-- chmod the containing project directory. Ordinary markdown is not adopted.
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
vim.cmd("runtime plugin/yap.lua")
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" }})

local paths = require("harness.path")
local frontmatter = require("harness.model.frontmatter")

local project = vim.fn.tempname()
vim.fn.mkdir(project, "p")
local portable = project .. "/portable-session.md"
local plain = project .. "/plain-note.md"

-- 1. Create a session at an arbitrary project path.
local buf = yap.new({ path = portable, provider = "mock", model = "m1" })
assert(vim.b[buf].yap == true, "portable session not marked yap")
assert(vim.b[buf].yap_path == portable, "transcript not at the requested path: " .. tostring(vim.b[buf].yap_path))
assert(not paths.under_sessions_root(portable), "test path must be outside the sessions root")

local fm = frontmatter.parse(vim.api.nvim_buf_get_lines(buf, 0, 30, false))
assert(fm and fm.data_dir, "portable session frontmatter missing data_dir")
assert(paths.under_sessions_root(fm.data_dir), "data_dir not centralised: " .. tostring(fm.data_dir))
assert(fm.data_dir ~= project, "data_dir must not be the project directory")

-- Sidecars resolve to the central directory, not beside the transcript.
assert(paths.audit_path(buf) == fm.data_dir .. "/audit.jsonl", "audit log not centralised")
assert(paths.assets_dir(buf) == fm.data_dir .. "/assets", "assets not centralised")
assert(vim.fn.filereadable(paths.notes_path(buf)) == 1, "portable session did not create its scratch")
yap.scratch_toggle(buf)
local notes = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(notes) == fm.data_dir .. "/notes.md", "portable scratch not centralised")
assert(vim.b[notes].yap == nil, "portable scratch adopted as transcript")
yap.scratch_toggle(buf)

-- The project directory keeps its mode (never chmod 0700 like a session dir).
assert(vim.fn.getfperm(project) ~= "rwx------", "project directory was chmod'd 0700")

-- 2. Reopening the file adopts it again and restores the central sidecars.
local reopened
vim.cmd("bwipeout!")
vim.cmd("edit " .. vim.fn.fnameescape(portable))
reopened = vim.api.nvim_get_current_buf()
assert(vim.b[reopened].yap == true, "portable transcript not adopted on reopen")
assert(vim.b[reopened].yap_data_dir == fm.data_dir, "data_dir not restored from frontmatter")
assert(paths.audit_path(reopened) == fm.data_dir .. "/audit.jsonl", "reopened audit log not centralised")
yap.scratch_toggle(reopened)
assert(vim.api.nvim_get_current_buf() == notes, "reopened portable session did not reuse its scratch")
yap.scratch_toggle(reopened)

-- A fork of a portable session is a rooted session: it must not inherit the
-- source's central data_dir (else its audit events would land in the source).
local session = require("harness.session")
local fork_path = session.fork(reopened, "portable-fork", false)
assert(fork_path, "portable fork failed")
assert(vim.fn.filereadable(vim.fn.fnamemodify(fork_path, ":h") .. "/notes.md") == 1,
  "fork did not create a scratch")
local fork_fm = frontmatter.parse(vim.fn.readfile(fork_path, "", 30))
assert(fork_fm.data_dir == vim.fn.fnamemodify(fork_path, ":h"),
  "fork must record its own sidecar directory as data_dir, not the source's")

-- 3. Ordinary markdown is left alone.
vim.cmd("enew")
vim.fn.writefile({ "# My notes", "", "nothing yap here" }, plain)
vim.cmd("edit " .. vim.fn.fnameescape(plain))
local plainbuf = vim.api.nvim_get_current_buf()
assert(vim.b[plainbuf].yap == nil, "ordinary markdown was adopted as a yap session")

-- 4. A bare `:Yap` lands under the sessions root, recording the sidecar
-- directory beside it as data_dir, so the .md can be moved out and still
-- find its audit log.
vim.cmd("bwipeout!")
local rooted = yap.new({ provider = "mock", model = "m1" })
assert(paths.under_sessions_root(vim.b[rooted].yap_path), "bare :Yap left the sessions root")
local rooted_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(rooted, 0, 30, false))
assert(rooted_fm.data_dir == vim.fn.fnamemodify(vim.b[rooted].yap_path, ":h"),
  "rooted session must record its own directory as data_dir")
assert(paths.audit_path(rooted) == vim.fn.fnamemodify(vim.b[rooted].yap_path, ":h") .. "/audit.jsonl", "rooted session sidecar layout changed")

-- 4a. Move the transcript out of its directory: reopening it elsewhere must
-- still find the audit log via the recorded data_dir.
local moved = vim.fn.tempname() .. "-moved.md"
vim.fn.rename(vim.b[rooted].yap_path, moved)
vim.cmd("bwipeout!")
vim.cmd("edit " .. vim.fn.fnameescape(moved))
local movedbuf = vim.api.nvim_get_current_buf()
assert(vim.b[movedbuf].yap == true, "moved transcript not adopted")
assert(paths.audit_path(movedbuf) == rooted_fm.data_dir .. "/audit.jsonl",
  "moved transcript lost its data_dir tie: " .. tostring(vim.b[movedbuf].yap_data_dir))
vim.cmd("bwipeout!")

-- 4b. `:Yap <path>` creates a portable session at an arbitrary path, and
-- `:Yap <dir>` drops session.md inside that directory.
vim.cmd("bwipeout!")
vim.cmd("Yap " .. vim.fn.fnameescape(project .. "/cli-session.md"))
local cli = vim.api.nvim_get_current_buf()
assert(vim.b[cli].yap_path == project .. "/cli-session.md", "command did not create the transcript at the given path: " .. tostring(vim.b[cli].yap_path))
local cli_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(cli, 0, 30, false))
assert(cli_fm and cli_fm.data_dir, ":Yap <path> session missing data_dir")
assert(paths.under_sessions_root(cli_fm.data_dir), ":Yap <path> data_dir not centralised")

vim.cmd("bwipeout!")
vim.cmd("Yap " .. vim.fn.fnameescape(project))
local dirsess = vim.api.nvim_get_current_buf()
assert(vim.b[dirsess].yap_path == project .. "/session.md", ":Yap <dir> did not create session.md inside it: " .. tostring(vim.b[dirsess].yap_path))
assert(frontmatter.parse(vim.api.nvim_buf_get_lines(dirsess, 0, 30, false)).data_dir ~= nil, ":Yap <dir> session missing data_dir")

-- 4c. `:Yap <path>` on an EXISTING transcript opens it (adoption), never
-- replaces it with a fresh template: a moved session.md resumed via :Yap
-- keeps its conversation and its data_dir tie.
local existing = project .. "/cli-session.md"
vim.cmd("Yap " .. vim.fn.fnameescape(existing))
local reopened_cli = vim.api.nvim_get_current_buf()
assert(vim.b[reopened_cli].yap == true, "existing transcript not adopted by :Yap")
assert(vim.b[reopened_cli].yap_path == existing, ":Yap on existing file changed its path")
local reopened_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(reopened_cli, 0, 30, false))
assert(reopened_fm and reopened_fm.data_dir == cli_fm.data_dir,
  ":Yap on existing file lost its data_dir tie")
assert(reopened_fm and reopened_fm.created_at == cli_fm.created_at,
  ":Yap on existing file created a NEW session (frontmatter replaced)")
assert(not vim.api.nvim_buf_get_lines(reopened_cli, 0, 3, false)[1]:match("^# @system$"),
  ":Yap on existing file replaced the transcript with a fresh template")
vim.cmd("bwipeout " .. reopened_cli)

-- 5. Portable sessions join the open-session overview and the winbar rollup
-- like any other open session (both are keyed on the yap buffer flag, not on
-- the path being under the sessions root).
vim.cmd("edit " .. vim.fn.fnameescape(portable))
reopened = vim.api.nvim_get_current_buf()
assert(vim.b[reopened].yap == true, "portable transcript not re-adopted")
local captured
local select = vim.ui.select
vim.ui.select = function(items)
  captured = items
end
yap.sessions("open")
vim.ui.select = select
local seen_portable, seen_dir = false, false
for _, item in ipairs(captured or {}) do
  if item.buf == reopened then
    seen_portable = true
  elseif item.buf == dirsess then
    seen_dir = true
  end
end
assert(seen_portable, "portable session missing from open-session overview")
assert(seen_dir, ":Yap <dir> session missing from open-session overview")

-- The dirsess rollup counts the reopened portable session as one idle other.
local bar = yap.winbar(dirsess)
assert(bar:match(yap.config.icons.idle .. "1"), "rollup missing portable session: " .. bar)

-- 5b. `:Yap <bare filename>` resolves against the cwd and gains the `.md`
-- suffix (spaces included); `:Yap ~<path>` expands against $HOME. Both stay
-- portable: the transcript lands where named, its data_dir under the root.
local here = vim.fn.getcwd()
vim.cmd("cd " .. vim.fn.fnameescape(project))

vim.cmd("bwipeout!")
vim.cmd("Yap this is a filename")
local bare = vim.api.nvim_get_current_buf()
assert(vim.b[bare].yap_path == project .. "/this is a filename.md",
  "bare filename did not resolve against cwd: " .. tostring(vim.b[bare].yap_path))
assert(frontmatter.parse(vim.api.nvim_buf_get_lines(bare, 0, 30, false)).data_dir ~= nil,
  "bare filename session missing data_dir")

vim.cmd("bwipeout!")
vim.cmd("Yap ~/from_home.md")
local homebuf = vim.api.nvim_get_current_buf()
assert(vim.b[homebuf].yap_path == vim.env.HOME .. "/from_home.md",
  "~ path did not expand: " .. tostring(vim.b[homebuf].yap_path))
assert(frontmatter.parse(vim.api.nvim_buf_get_lines(homebuf, 0, 30, false)).data_dir ~= nil,
  "~ path session missing data_dir")

vim.cmd("bwipeout!")
-- 6. `:w <path>` moves the session: the buffer adopts the new transcript
-- path (keeping its data_dir tie), and a later save in the moved buffer never
-- recreates the deleted original.
local moved = project .. "/w-moved.md"
vim.cmd("Yap " .. vim.fn.fnameescape(project .. "/w-source.md"))
local wbuf = vim.api.nvim_get_current_buf()
local w_orig = vim.b[wbuf].yap_path
local w_data = vim.b[wbuf].yap_data_dir
vim.cmd("write " .. vim.fn.fnameescape(moved))
assert(vim.b[wbuf].yap_path == moved, ":w <path> did not move the session")
assert(vim.fn.filereadable(moved) == 1, ":w <path> did not write the new file")
assert(vim.b[wbuf].yap_data_dir == w_data, ":w <path> must keep the data_dir tie")
vim.fn.delete(w_orig)
require("harness.session").save(wbuf)
assert(vim.fn.filereadable(w_orig) == 0, "save recreated the deleted original")
assert(vim.fn.filereadable(moved) == 1, "moved transcript missing after save")
-- reopening the moved file keeps the tie
vim.cmd("bwipeout! " .. wbuf)
vim.cmd("edit " .. vim.fn.fnameescape(moved))
local reopened_moved = vim.api.nvim_get_current_buf()
assert(vim.b[reopened_moved].yap == true, "moved transcript not adopted")
assert(vim.b[reopened_moved].yap_data_dir == w_data, "moved transcript lost its data_dir")
vim.cmd("bwipeout! " .. reopened_moved)
vim.fn.delete(moved)

vim.cmd("cd " .. vim.fn.fnameescape(here))

print("OK portable session")

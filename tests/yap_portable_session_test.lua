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

-- A fork of a portable session is a rooted session: it must not inherit the
-- source's central data_dir (else its audit events would land in the source).
local session = require("harness.session")
local fork_path = session.fork(reopened, "portable-fork", false)
assert(fork_path, "portable fork failed")
local fork_fm = frontmatter.parse(vim.fn.readfile(fork_path, "", 30))
assert(fork_fm.data_dir == nil, "fork inherited the source's central data_dir")

-- 3. Ordinary markdown is left alone.
vim.cmd("enew")
vim.fn.writefile({ "# My notes", "", "nothing yap here" }, plain)
vim.cmd("edit " .. vim.fn.fnameescape(plain))
local plainbuf = vim.api.nvim_get_current_buf()
assert(vim.b[plainbuf].yap == nil, "ordinary markdown was adopted as a yap session")

-- 4. A bare `:Yap` still lands under the sessions root with no data_dir.
vim.cmd("bwipeout!")
local rooted = yap.new({ provider = "mock", model = "m1" })
assert(paths.under_sessions_root(vim.b[rooted].yap_path), "bare :Yap left the sessions root")
local rooted_fm = frontmatter.parse(vim.api.nvim_buf_get_lines(rooted, 0, 30, false))
assert(rooted_fm.data_dir == nil, "rooted session should have no data_dir (sidecars beside it)")
assert(paths.audit_path(rooted) == vim.fn.fnamemodify(vim.b[rooted].yap_path, ":h") .. "/audit.jsonl", "rooted session sidecar layout changed")

-- 5. Portable sessions join the open-session overview and the winbar rollup
-- like any other open session (both are keyed on the yap buffer flag, not on
-- the path being under the sessions root).
local captured
local select = vim.ui.select
vim.ui.select = function(items)
  captured = items
end
yap.instances()
vim.ui.select = select
local seen_portable, seen_rooted = false, false
for _, item in ipairs(captured or {}) do
  if item.buf == reopened then
    seen_portable = true
  elseif item.buf == rooted then
    seen_rooted = true
  end
end
assert(seen_portable, "portable session missing from open-session overview")
assert(seen_rooted, "rooted session missing from open-session overview")

-- The rooted session's rollup counts the portable session as one idle other.
local bar = yap.winbar(rooted)
assert(bar:match(yap.config.icons.idle .. "1"), "rollup missing portable session: " .. bar)

print("OK portable session")

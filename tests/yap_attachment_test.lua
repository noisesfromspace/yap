local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
yap.setup({ bin = ROOT .. "/yap" })

local source = vim.fn.tempname() .. " photo.png"
local image = "\137PNG\r\n\26\n" .. string.rep("x", 50)
local fd = assert(vim.uv.fs_open(source, "w", 384))
assert(vim.uv.fs_write(fd, image, 0) == #image)
vim.uv.fs_close(fd)
local buf = yap.new()
local row = vim.api.nvim_buf_line_count(buf)
local escaped = source:gsub(" ", "\\ ")
vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { escaped })
vim.api.nvim_win_set_cursor(0, { row, 0 })
local ref, err = require("harness.agent.attachment").attach()
assert(ref, err)
assert(ref:match("^!%[FILE: .+%]%(%s*file://"), ref)
assert(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] == ref)
local path = vim.uri_to_fname(ref:match("%((file://[^)]+)%)"))
local read = assert(vim.uv.fs_open(path, "r", 0))
assert(vim.uv.fs_read(read, #image, 0) == image)
vim.uv.fs_close(read)

-- The import is audited: one attachment event carrying the full metadata.
local paths = require("harness.path")
local apath = paths.audit_path(buf)
assert(vim.fn.filereadable(apath) == 1, "audit log missing after attach")
local att
for _, line in ipairs(vim.fn.readfile(apath)) do
  if line ~= "" then
    local ok, ev = pcall(vim.json.decode, line)
    if ok and ev.type == "attachment" then
      att = ev
    end
  end
end
assert(att, "no attachment event in audit log")
assert(att.source == vim.fn.fnamemodify(source, ":p"), "attachment source wrong: " .. vim.inspect(att))
assert(att.asset == path, "attachment asset wrong: " .. vim.inspect(att))
assert(att.bytes == #image, "attachment bytes wrong: " .. vim.inspect(att))
assert(att.format == "png", "attachment format wrong: " .. vim.inspect(att))

-- The copy lives in the session's own assets folder, so the session is
-- self-contained (no shared store, no separate manifest).
local adir = paths.assets_dir(buf)
assert(path:sub(1, #adir + 1) == adir .. "/", "asset not in the session assets folder: " .. path)

local messages = yap.parse_buffer(buf)
assert(messages[#messages].role == "user" and messages[#messages].content == ref)

-- A dropped standalone path is imported automatically by the send preflight.
local auto = yap.new()
local last = vim.api.nvim_buf_line_count(auto)
vim.api.nvim_buf_set_lines(auto, last - 1, last, false, { "Describe this picture", escaped })
assert(require("harness.agent.attachment").import_paths(auto))
local lines = vim.api.nvim_buf_get_lines(auto, last - 1, last + 1, false)
assert(lines[1] == "Describe this picture", vim.inspect(lines))
local auto_ref = lines[2]
assert(auto_ref:match("^!%[FILE: .+%]%(%s*file://"), vim.inspect(lines))
assert(auto_ref ~= ref, "each session should get its own copy: " .. vim.inspect(lines))
local auto_asset = vim.uri_to_fname(auto_ref:match("%((file://[^)]+)%)"))
assert(vim.fn.filereadable(auto_asset) == 1, "auto-imported asset missing: " .. auto_asset)
assert(
  auto_asset:sub(1, #paths.assets_dir(auto) + 1) == paths.assets_dir(auto) .. "/",
  "auto asset not in session folder: " .. auto_asset
)
assert(require("harness.agent.attachment").import_paths(auto)) -- subsequent sends do not re-import
assert(vim.api.nvim_buf_get_lines(auto, last, last + 1, false)[1] == auto_ref)

local other = yap.new()
local endline = vim.api.nvim_buf_line_count(other)
vim.api.nvim_buf_set_lines(other, endline - 1, endline, false, {
  "A path in prose: " .. source,
  "/missing/file.png",
})
local ok, failure = require("harness.agent.attachment").import_paths(other)
assert(not ok and failure:find("expected a local image", 1, true), tostring(failure))

-- A failed import is audited too: the error plus the attempted source.
local opath = paths.audit_path(other)
local fail
for _, line in ipairs(vim.fn.readfile(opath)) do
  if line ~= "" then
    local ok2, ev = pcall(vim.json.decode, line)
    if ok2 and ev.type == "attachment" and ev.error then
      fail = ev
    end
  end
end
assert(fail, "no failed-attachment event in audit log")
assert(fail.source == "/missing/file.png", "failure source wrong: " .. vim.inspect(fail))
assert(fail.error:find("expected a local image", 1, true), "failure error wrong: " .. vim.inspect(fail))

assert(vim.api.nvim_buf_get_lines(other, endline - 1, endline, false)[1] == "A path in prose: " .. source)
print("OK attachment")

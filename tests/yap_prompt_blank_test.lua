-- A trailing `# @user` prompt must always be followed by a blank line so the
-- user can start typing with i/p instead of o. Covers the unit guarantee and
-- the repair of a saved transcript that ends on the heading itself (older
-- builds and hand edits).
local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local yap = require("harness")
local document = require("harness.model.document")
local paths = require("harness.path")
yap.setup({ bin = ROOT .. "/yap", model_groups = { agent = "mock/m1", flash = "" } })

local function tail(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- A heading-only tail is repaired; an already-blank prompt and a non-user
-- tail are left untouched.
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "# @user" })
document.ensure_prompt_blank(b)
local l = tail(b)
assert(l[#l] == "" and l[#l - 1] == "# @user", "heading-only tail not repaired: " .. vim.inspect(l))

local b2 = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "# @user", "" })
document.ensure_prompt_blank(b2)
local l2 = tail(b2)
assert(#l2 == 2 and l2[1] == "# @user" and l2[2] == "", "already-blank prompt changed: " .. vim.inspect(l2))

local b3 = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(b3, 0, -1, false, { "# @assistant", "hi" })
document.ensure_prompt_blank(b3)
assert(tail(b3)[#tail(b3)] == "hi", "assistant tail should be left alone")

-- Adopting a saved transcript that ends on `# @user` repairs the prompt.
local dir = paths.session_dir(vim.fn.getcwd()) .. "/prompt-blank"
vim.fn.mkdir(dir, "p")
local lines = {
  "---",
  "model: mock",
  "provider: mock",
  "created_at: 2026-11-20T00:00:00Z",
  "updated_at: 2026-11-20T00:00:00Z",
  "turns: 1",
  "---",
  "",
  "# @system",
  "",
  "sys",
  "",
  "# @assistant",
  "",
  "answer",
  "",
  "# @user",
}
local file = dir .. "/session.md"
vim.fn.writefile(lines, file)
yap.open(file)
local adopted = vim.api.nvim_get_current_buf()
local t = tail(adopted)
assert(
  t[#t] == "" and t[#t - 1] == "# @user",
  "adopt did not repair the trailing prompt: " .. vim.inspect(vim.list_slice(t, #t - 2))
)

print("OK prompt blank")

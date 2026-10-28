local ROOT = vim.env.YAP_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(ROOT)
local structure = require("harness.model.structure")
local cases = vim.json.decode(table.concat(vim.fn.readfile(ROOT .. "/tests/transcript_cases.json"), "\n"))
local buf = vim.api.nvim_create_buf(false, true)
local function norm(p)
  local out = { headings = {}, regions = {}, frontmatter = p.frontmatter or 0 }
  for _, h in ipairs(p.headings) do out.headings[#out.headings + 1] = { role = h.role, line = h.line } end
  for _, r in ipairs(p.regions) do
    out.regions[#out.regions + 1] = {
      kind = r.kind, start = r.start, finish = r.finish,
      header_finish = r.header_finish, ui_start = r.ui_start, ui_finish = r.ui_finish,
      unclosed = r.unclosed,
    }
  end
  return out
end
for _, c in ipairs(cases) do
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(c.text, "\n", { plain = true }))
  local got = norm(structure.parse(buf))
  for _, key in ipairs({ "headings", "regions", "frontmatter" }) do
    assert(vim.deep_equal(got[key], c[key]), c.name .. " differs at " .. key .. ": " .. vim.inspect(got[key]))
  end
end
vim.api.nvim_buf_delete(buf, { force = true })
print("OK transcript conformance")

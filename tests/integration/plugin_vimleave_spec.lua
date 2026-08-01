local test = require("tests.testlib")

-- Preconditions: The lazy plugin loader has registered the public command layer.
-- Prerequisites: VimLeavePre must initiate non-interactive force disposal and the
-- registration must remain idempotent across repeated plugin loads. Verification
-- items: exactly one Bilingua-owned exit autocmd exists with its documented
-- description, allowing the callback implementation to be audited independently.
test.it("registers one VimLeavePre force-disposal hook", function()
  vim.g.loaded_bilingua_nvim = nil
  dofile("plugin/bilingua.lua")
  dofile("plugin/bilingua.lua")

  local matches = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "VimLeavePre" })) do
    if autocmd.desc == "Dispose all Bilingua Sessions" then
      matches[#matches + 1] = autocmd
    end
  end
  test.eq(1, #matches)
end)

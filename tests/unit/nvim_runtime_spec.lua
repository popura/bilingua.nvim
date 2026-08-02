local test = require("tests.testlib")
local runtime_module = require("bilingua.ui.nvim_runtime")

-- Preconditions: A temporary Codex home contains both supported global
-- instruction filenames and no other Codex state. Prerequisites: Runtime
-- discovery checks the real filesystem and receives an explicit home path so
-- the test never reads or changes the user's Codex configuration. Verification
-- items: both exact existing file paths are passed to the backend in priority
-- order, and the temporary directory is removed before assertions can fail.
test.it("allows the existing global Codex instruction files by exact path", function()
  local separator = package.config:sub(1, 1)
  local codex_home = vim.fn.tempname() .. "-bilingua-codex-home"
  assert(vim.fn.mkdir(codex_home, "p", 448) == 1)
  local override_path = codex_home .. separator .. "AGENTS.override.md"
  local agents_path = codex_home .. separator .. "AGENTS.md"
  assert(vim.fn.writefile({ "temporary override" }, override_path) == 0)
  assert(vim.fn.writefile({ "temporary guidance" }, agents_path) == 0)

  local constructed, runtime = pcall(runtime_module.new, { codex_home = codex_home })
  local removed = vim.fn.delete(codex_home, "rf") == 0

  test.eq(true, constructed)
  test.eq(true, removed)
  test.eq({ override_path, agents_path }, runtime.backend_runtime.allowed_instruction_sources)
end)

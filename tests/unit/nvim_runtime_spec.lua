local test = require("tests.testlib")
local runtime_module = require("bilingua.ui.nvim_runtime")

-- Preconditions: The Neovim runtime is available without starting a backend
-- process. Prerequisites: Codex latency measurements require a monotonic clock
-- supplied through backend_runtime rather than direct Neovim access in the
-- backend adapter. Verification items: now_ms returns finite numeric values and
-- never decreases across consecutive observations.
test.it("provides a monotonic backend clock", function()
  local runtime = runtime_module.new()
  local first = runtime.backend_runtime.now_ms()
  local second = runtime.backend_runtime.now_ms()

  test.eq("number", type(first))
  test.eq(true, first == first and first ~= math.huge and first ~= -math.huge)
  test.eq(true, second >= first)
end)

-- Preconditions: Neovim provides its bundled Markdown parser, and this repository
-- contributes queries/markdown/bilingua.scm through runtimepath. Prerequisites:
-- current Neovim may expose vim.treesitter.query.get as a callable table (a table
-- with __call) instead of a Lua function, so runtime detection must exercise the
-- API instead of rejecting its representation. Verification items: Markdown is
-- reported as available and the repository query captures a simple heading.
test.it("accepts the installed Tree-sitter Markdown parser and query", function()
  local runtime = runtime_module.new()
  local available, availability_error = runtime.document_runtime.markdown_available()

  test.eq(nil, availability_error)
  test.eq(true, available)

  local analysis, analysis_error = runtime.document_runtime.analyze_markdown("# Heading\n")
  test.eq(nil, analysis_error)
  test.eq("table", type(analysis))
  test.eq(true, analysis.capture_count > 0)
end)

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

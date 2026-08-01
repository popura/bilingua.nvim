local test = require("tests.testlib")

local API_METHODS = {
  "setup",
  "start",
  "toggle",
  "sync_current",
  "sync_all",
  "use_source",
  "use_japanese",
  "next_group",
  "prev_group",
  "retry_current",
  "restart_backend",
  "stop",
  "quit",
  "status",
}

-- Preconditions: Requiring the public module must not start a backend or create a
-- target buffer. Prerequisites: setup performs validation while the command layer
-- remains independently loadable. Verification items: the full documented Lua
-- API exists, valid setup succeeds, and unsupported persistence is rejected with
-- the stable E_INVALID_ARGUMENT code rather than a Lua exception.
test.it("exposes the documented Lua API and validates setup options", function()
  local bilingua = require("bilingua")
  for _, method in ipairs(API_METHODS) do
    test.eq("function", type(bilingua[method]))
  end

  local configured, configure_error = bilingua.setup({ mappings = { enabled = false } })
  test.eq(true, configured)
  test.eq(nil, configure_error)

  local invalid, invalid_error = bilingua.setup({ persistence = { enabled = true } })
  test.eq(nil, invalid)
  test.eq("E_INVALID_ARGUMENT", invalid_error.code)

  -- Restore a valid configuration so later integration tests do not inherit the
  -- deliberately invalid setup request from this singleton public module.
  assert(bilingua.setup({ mappings = { enabled = false } }))
end)

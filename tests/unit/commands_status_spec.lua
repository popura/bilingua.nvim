local commands = require("bilingua.commands")
local test = require("tests.testlib")

local function status(overrides)
  local value = {
    state = "ready",
    health = "healthy",
    source_buf = 1,
    target_buf = 2,
    source_language = "en",
    target_language = "ja",
    document_adapter = "plaintext",
    tracker = "hybrid",
    aligner = "generated_id",
    backend = "codex_app_server",
    groups = {},
    automatic_sync = true,
    automatic_sync_configured = true,
    automatic_sync_paused = false,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

-- Preconditions: A ready Session is healthy and automatic synchronization is
-- configured and running. Prerequisites: format_status receives only a status
-- snapshot and must not inspect Session internals. Verification items: the text
-- reports both runtime health and effective automatic synchronization state.
test.it("reports healthy runtime status and enabled automatic synchronization", function()
  local output = commands.format_status(status())

  test.eq(true, output:find("Health: healthy", 1, true) ~= nil)
  test.eq(true, output:find("Auto sync: enabled", 1, true) ~= nil)
end)

-- Preconditions: A fatal backend error can pause automatic synchronization
-- while the user's configuration still enables it. Prerequisites: the status
-- snapshot exposes configured, effective, and paused flags independently.
-- Verification items: format_status says paused rather than disabled so the
-- operator can choose BilinguaRestartBackend instead of changing configuration.
test.it("distinguishes paused automatic synchronization from disabled configuration", function()
  local output = commands.format_status(status({
    health = "degraded",
    automatic_sync = false,
    automatic_sync_paused = true,
  }))

  test.eq(true, output:find("Health: degraded", 1, true) ~= nil)
  test.eq(true, output:find("Auto sync: paused", 1, true) ~= nil)
end)

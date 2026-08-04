local test = require("tests.testlib")
local config = require("bilingua.config")

-- Preconditions: One caller resolves defaults, mutates its private result, and a
-- second caller resolves defaults again; another caller enables forbidden MVP
-- persistence. Prerequisites: Session settings must not share mutable tables and
-- unsupported persistence must fail explicitly rather than silently falling back.
-- Verification items: documented defaults are present, results are independent,
-- and persistence.enabled=true returns E_INVALID_ARGUMENT.
test.it("resolves isolated defaults and rejects persistent sessions", function()
  local first = assert(config.resolve({}))
  test.eq("auto", first.source_language)
  test.eq("ja", first.target_language)
  test.eq(700, first.sync.debounce_ms)
  test.eq(false, first.layout.open_folds)
  test.eq("codex_app_server", first.translation.backend)
  test.eq(true, first.translation.backend_options.experimental_api)
  first.sync.debounce_ms = 1

  local second = assert(config.resolve({}))
  test.eq(700, second.sync.debounce_ms)

  local resolved, err = config.resolve({ persistence = { enabled = true } })
  test.eq(nil, resolved)
  test.eq("E_INVALID_ARGUMENT", err.code)
end)

-- Preconditions: A caller resolves the unmodified plugin defaults.
-- Prerequisites: The production Codex route and the opt-in live test must share
-- one explicit model/effort baseline instead of inheriting an account default.
-- Verification items: model selection is pinned to GPT-5.6 Luna and reasoning
-- effort is pinned to max.
test.it("pins the default Codex model and effort for live verification", function()
  local resolved = assert(config.resolve({}))

  test.eq("gpt-5.6-luna", resolved.translation.backend_options.model)
  test.eq("max", resolved.translation.backend_options.reasoning_effort)
end)

-- Preconditions: Strict isolation is requested while the Codex experimental API
-- is disabled. Prerequisites: config.lua owns backend namespace shape but concrete
-- backends own their option semantics. Verification items: resolution preserves the
-- contradictory values for the Codex constructor and returns no config error.
test.it("defers Codex option semantics to the selected backend", function()
  local resolved, resolve_error = config.resolve({
    translation = {
      backend_options = {
        strict_isolation = true,
        experimental_api = false,
      },
    },
  })

  test.eq(nil, resolve_error)
  test.eq(true, resolved.translation.backend_options.strict_isolation)
  test.eq(false, resolved.translation.backend_options.experimental_api)
end)

-- Preconditions: Callers provide wrong primitive types or out-of-range values for
-- documented boolean, timeout, isolation, and display options. Prerequisites: all
-- documented setup fields are validated before any Session is constructed.
-- Verification items: every malformed option returns E_INVALID_ARGUMENT and its
-- public error message identifies the exact configuration path.
test.it("validates every documented scalar configuration category", function()
  local cases = {
    { { source_language = "" }, "source_language" },
    { { layout = { follow_cursor = "yes" } }, "layout.follow_cursor" },
    { { layout = { open_folds = "yes" } }, "layout.open_folds" },
    { { sync = { automatic = 1 } }, "sync.automatic" },
    { { sync = { on_insert_leave = "yes" } }, "sync.on_insert_leave" },
    { { sync = { retry = { max_delay_ms = 499 } } }, "sync.retry.max_delay_ms" },
    { { stop = { sync_pending = "yes" } }, "stop.sync_pending" },
    { { stop = { timeout_ms = 0 } }, "stop.timeout_ms" },
    { { documents = { fallback_to_plaintext = "yes" } }, "documents.fallback_to_plaintext" },
    { { translation = { backend = "" } }, "translation.backend" },
    { { ui = { signs = "yes" } }, "ui.signs" },
    { { debug = { enabled = "yes" } }, "debug.enabled" },
  }

  for _, case in ipairs(cases) do
    local resolved, err = config.resolve(case[1])
    test.eq(nil, resolved)
    test.eq("E_INVALID_ARGUMENT", err.code)
    assert(err.message:find(case[2], 1, true), err.message)
  end
end)

-- Preconditions: A filetype alias maps an alternate name to an existing exact
-- route. Prerequisites: aliases are string-to-string route references and must
-- never silently point at missing routes. Verification items: valid aliases survive
-- resolution, while a dangling alias is rejected with its precise option path.
test.it("validates filetype aliases against configured routes", function()
  local resolved = assert(config.resolve({
    documents = { aliases = { md = "markdown" } },
  }))
  test.eq("markdown", resolved.documents.aliases.md)

  local invalid, err = config.resolve({
    documents = { aliases = { md = "missing" } },
  })
  test.eq(nil, invalid)
  test.eq("E_INVALID_ARGUMENT", err.code)
  assert(err.message:find("documents.aliases.md", 1, true), err.message)
end)

-- Preconditions: Callers replace the default two-part Codex command with one
-- executable and with an empty list in separate resolution requests.
-- Prerequisites: array-valued options replace atomically, while the concrete Codex
-- backend—not config.lua—validates whether the resulting list can start a process.
-- Verification items: both replacements survive exactly without inherited elements.
test.it("replaces command arrays without retaining default elements", function()
  local resolved = assert(config.resolve({
    translation = { backend_options = { command = { "custom-server" } } },
  }))
  test.eq({ "custom-server" }, resolved.translation.backend_options.command)

  local empty = assert(config.resolve({
    translation = { backend_options = { command = {} } },
  }))
  test.eq({}, empty.translation.backend_options.command)
end)

-- Preconditions: A caller supplies one valid custom Lua pattern, while separate
-- callers supply a malformed pattern and a non-list table. Prerequisites: custom
-- protected-token patterns are atomic ordered configuration and are compiled only
-- after setup validation. Verification items: the valid list survives exactly,
-- and both malformed shapes fail with E_INVALID_ARGUMENT naming the option path.
test.it("validates custom protected-token patterns as an atomic list", function()
  local resolved = assert(config.resolve({
    documents = { protected_patterns = { "TOKEN:%d+" } },
  }))
  test.eq({ "TOKEN:%d+" }, resolved.documents.protected_patterns)

  for _, patterns in ipairs({ { "[" }, { named = "TOKEN:%d+" } }) do
    local invalid, err = config.resolve({ documents = { protected_patterns = patterns } })
    test.eq(nil, invalid)
    test.eq("E_INVALID_ARGUMENT", err.code)
    assert(err.message:find("documents.protected_patterns", 1, true), err.message)
  end
end)

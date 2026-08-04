local test = require("tests.testlib")
local config = require("bilingua.config")

-- Preconditions: Defaults are requested once, then llama_server is selected with
-- backend-specific endpoint, model, and command overrides.
-- Prerequisites: every backend owns one option table below translation.backends;
-- selecting one backend must not create a second flat view of those options.
-- Verification items: Codex remains the default with its pinned model, llama keeps
-- its own defaults and overrides, and Codex-only command and isolation fields do
-- not enter llama options.
test.it("resolves options only from backend-specific tables", function()
  local defaults = config.defaults()
  test.eq("codex_app_server", defaults.translation.backend)
  test.eq("gpt-5.6-luna", defaults.translation.backends.codex_app_server.model)
  test.eq("http://127.0.0.1:8080", defaults.translation.backends.llama_server.endpoint)

  local resolved = assert(config.resolve({
    translation = {
      backend = "llama_server",
      backends = {
        llama_server = {
          endpoint = "http://localhost:8080",
          model = "nested-model",
          curl_command = { "custom-curl" },
        },
      },
    },
  }))

  local nested = resolved.translation.backends.llama_server
  test.eq("http://localhost:8080", nested.endpoint)
  test.eq("nested-model", nested.model)
  test.eq({ "custom-curl" }, nested.curl_command)
  test.eq(30000, nested.open_timeout_ms)
  test.eq(nil, nested.command)
  test.eq(nil, nested.strict_isolation)
end)

-- Preconditions: One caller adds a backend-specific extension option to the
-- built-in llama_server table; another selects a fully custom backend and options.
-- Prerequisites: translation.backends is a dynamic registry-owned namespace, so
-- config validates only its generic shape and does not own backend option names.
-- Verification items: both option sets survive unchanged in their backend-specific
-- tables, and neither supported extension path produces an unknown-key warning.
test.it("preserves custom backend IDs and option keys without warnings", function()
  local llama, llama_error, llama_warnings = config.resolve({
    translation = {
      backend = "llama_server",
      backends = {
        llama_server = {
          provider_extension = { enabled = true },
        },
      },
    },
  })
  test.eq(nil, llama_error)
  test.eq({}, llama_warnings)
  test.eq(true, llama.translation.backends.llama_server.provider_extension.enabled)

  local custom, custom_error, custom_warnings = config.resolve({
    translation = {
      backend = "custom_backend",
      backends = {
        custom_backend = {
          command = { "custom" },
          arbitrary_option = "retained",
        },
      },
    },
  })
  test.eq(nil, custom_error)
  test.eq({}, custom_warnings)
  test.eq("retained", custom.translation.backends.custom_backend.arbitrary_option)
  test.eq({ "custom" }, custom.translation.backends.custom_backend.command)
end)

-- Preconditions: A source configuration is resolved twice and defaults are read
-- twice; the first resolved backend table and first defaults are then mutated.
-- Prerequisites: config resolution deep-copies caller data, defaults, arrays, and
-- nested option maps for every Session.
-- Verification items: source input and later results retain their original nested
-- command and extension values without relying on a duplicate option table.
test.it("isolates backend option tables across every resolution boundary", function()
  local source = {
    translation = {
      backend = "llama_server",
      backends = {
        llama_server = {
          curl_command = { "source-curl" },
          provider_extension = { mode = "source" },
        },
      },
    },
  }
  local first = assert(config.resolve(source))
  first.translation.backends.llama_server.curl_command[1] = "resolved-change"
  first.translation.backends.llama_server.provider_extension.mode = "resolved-change"

  test.eq("source-curl", source.translation.backends.llama_server.curl_command[1])
  test.eq("source", source.translation.backends.llama_server.provider_extension.mode)

  local second = assert(config.resolve(source))
  test.eq("source-curl", second.translation.backends.llama_server.curl_command[1])
  test.eq("source", second.translation.backends.llama_server.provider_extension.mode)

  local first_defaults = config.defaults()
  first_defaults.translation.backends.codex_app_server.command[1] = "changed"
  first_defaults.translation.backends.llama_server.curl_command[1] = "changed-curl"

  local second_defaults = config.defaults()
  test.eq({ "codex", "app-server" }, second_defaults.translation.backends.codex_app_server.command)
  test.eq({ "curl" }, second_defaults.translation.backends.llama_server.curl_command)
end)

-- Preconditions: A caller supplies the removed translation.backend_options key
-- together with a valid backend-specific model value.
-- Prerequisites: unknown configuration keys are reported and ignored; removed
-- settings must not override or reappear in the resolved configuration.
-- Verification items: the current nested model remains effective, backend_options
-- is absent, and the caller receives the exact unknown-key warning.
test.it("does not recognize the removed backend_options setting", function()
  local resolved, resolve_error, warnings = config.resolve({
    translation = {
      backends = {
        codex_app_server = { model = "current-model" },
      },
      backend_options = { model = "removed-model" },
    },
  })

  test.eq(nil, resolve_error)
  test.eq("current-model", resolved.translation.backends.codex_app_server.model)
  test.eq(nil, resolved.translation.backend_options)
  test.eq({ "Unknown configuration key: translation.backend_options" }, warnings)
end)

-- Preconditions: Callers provide malformed containers, backend IDs, or option
-- tables while leaving all unrelated configuration valid.
-- Prerequisites: config.lua owns only backend namespace shape, selected ID shape,
-- and the global translation timeout.
-- Verification items: every malformed shape returns E_INVALID_ARGUMENT and names
-- the generic configuration path without applying Codex or llama field rules.
test.it("validates only generic backend configuration shapes", function()
  local cases = {
    { { translation = { backends = "invalid" } }, "translation.backends" },
    {
      {
        translation = {
          backend = "llama_server",
          backends = { llama_server = "invalid" },
        },
      },
      "translation.backends.llama_server",
    },
    { { translation = { backends = { [""] = {} } } }, "translation.backends keys" },
    { { translation = { timeout_ms = 0 } }, "translation.timeout_ms" },
  }

  for _, case in ipairs(cases) do
    local resolved, config_error = config.resolve(case[1])
    test.eq(nil, resolved)
    test.eq("E_INVALID_ARGUMENT", config_error.code)
    test.eq(true, config_error.message:find(case[2], 1, true) ~= nil)
  end
end)

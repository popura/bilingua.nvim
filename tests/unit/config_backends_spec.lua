local test = require("tests.testlib")
local config = require("bilingua.config")

-- Preconditions: Defaults are requested once, then llama_server is selected with
-- nested options and explicit legacy backend_options that override the same model.
-- Prerequisites: resolution order is built-in defaults, selected nested options,
-- then legacy options; backend_options remains only a compatibility mirror.
-- Verification items: Codex remains the default with its pinned model, llama keeps
-- its own defaults and overrides, legacy wins last, both resolved tables match,
-- and Codex-only command and isolation fields do not enter llama options.
test.it("resolves and mirrors options for only the selected backend", function()
  local defaults = config.defaults()
  test.eq("codex_app_server", defaults.translation.backend)
  test.eq("gpt-5.6-luna", defaults.translation.backends.codex_app_server.model)
  test.eq("gpt-5.6-luna", defaults.translation.backend_options.model)
  test.eq("http://127.0.0.1:8080", defaults.translation.backends.llama_server.endpoint)

  local resolved = assert(config.resolve({
    translation = {
      backend = "llama_server",
      backends = {
        llama_server = {
          endpoint = "http://localhost:8080",
          model = "nested-model",
        },
      },
      backend_options = {
        model = "legacy-model",
        curl_command = { "custom-curl" },
      },
    },
  }))

  local nested = resolved.translation.backends.llama_server
  test.eq("http://localhost:8080", nested.endpoint)
  test.eq("legacy-model", nested.model)
  test.eq({ "custom-curl" }, nested.curl_command)
  test.eq(30000, nested.open_timeout_ms)
  test.eq(nested, resolved.translation.backend_options)
  test.eq(nil, nested.command)
  test.eq(nil, nested.strict_isolation)
end)

-- Preconditions: One caller adds a backend-specific extension option to the
-- built-in llama_server table; another selects a fully custom backend and options.
-- Prerequisites: translation.backends is a dynamic registry-owned namespace, so
-- config validates only its generic shape and does not own backend option names.
-- Verification items: both option sets survive unchanged, selected options are
-- mirrored, and neither supported extension path produces an unknown-key warning.
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
  test.eq(true, llama.translation.backend_options.provider_extension.enabled)

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
  test.eq("retained", custom.translation.backend_options.arbitrary_option)
  test.eq({ "custom" }, custom.translation.backends.custom_backend.command)
end)

-- Preconditions: A source configuration is resolved twice and defaults are read
-- twice; the first values and both views of its selected options are then mutated.
-- Prerequisites: config resolution deep-copies caller data, defaults, arrays, nested
-- option maps, and the legacy mirror for every Session.
-- Verification items: source input and later results retain original values, while
-- mutating backend_options does not mutate the selected nested option table.
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
  first.translation.backend_options.curl_command[1] = "mirror-change"
  first.translation.backend_options.provider_extension.mode = "mirror-change"

  test.eq("source-curl", first.translation.backends.llama_server.curl_command[1])
  test.eq("source", first.translation.backends.llama_server.provider_extension.mode)
  test.eq("source-curl", source.translation.backends.llama_server.curl_command[1])
  test.eq("source", source.translation.backends.llama_server.provider_extension.mode)

  local second = assert(config.resolve(source))
  test.eq("source-curl", second.translation.backend_options.curl_command[1])
  test.eq("source", second.translation.backend_options.provider_extension.mode)

  local first_defaults = config.defaults()
  first_defaults.translation.backends.codex_app_server.command[1] = "changed"
  first_defaults.translation.backend_options.command[1] = "mirror-changed"
  first_defaults.translation.backends.llama_server.curl_command[1] = "changed-curl"

  local second_defaults = config.defaults()
  test.eq({ "codex", "app-server" }, second_defaults.translation.backends.codex_app_server.command)
  test.eq({ "codex", "app-server" }, second_defaults.translation.backend_options.command)
  test.eq({ "curl" }, second_defaults.translation.backends.llama_server.curl_command)
end)

-- Preconditions: Callers provide malformed containers, backend IDs, or option
-- tables while leaving all unrelated configuration valid.
-- Prerequisites: config.lua owns only backend namespace shape, selected ID shape,
-- compatibility mirror shape, and the global translation timeout.
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
    { { translation = { backend_options = "invalid" } }, "translation.backend_options" },
    { { translation = { timeout_ms = 0 } }, "translation.timeout_ms" },
  }

  for _, case in ipairs(cases) do
    local resolved, config_error = config.resolve(case[1])
    test.eq(nil, resolved)
    test.eq("E_INVALID_ARGUMENT", config_error.code)
    test.eq(true, config_error.message:find(case[2], 1, true) ~= nil)
  end
end)

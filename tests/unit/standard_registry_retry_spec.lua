local test = require("tests.testlib")
local config_module = require("bilingua.config")
local registry_module = require("bilingua.registry")
local standard_registry = require("bilingua.standard_registry")

-- Preconditions: Standard factories receive a resolved configuration and the
-- SessionFactory delay scheduler in component context. Prerequisites: production
-- retries must use Session-owned timers so force disposal can cancel them.
-- Verification items: configured attempt/backoff values reach TranslationService,
-- its defer function delegates to the shared scheduler, and the returned cancel
-- token is preserved.
test.it("injects configured retry policy and the Session scheduler", function()
  local registry = registry_module.new()
  assert(standard_registry.register(registry))
  local config = config_module.defaults()
  config.sync.retry = { max_attempts = 4, initial_delay_ms = 25, max_delay_ms = 200 }
  local observed
  local token = { cancel = function() end }
  local scheduler = {
    schedule = function(_, callback)
      callback()
    end,
    defer = function(_, milliseconds, callback)
      observed = { milliseconds = milliseconds, callback = callback }
      return token
    end,
  }
  local service = registry:get_translation_service("default")(config, {
    session_id = "session:retry-wiring",
    registry = registry,
    scheduler = scheduler,
    backend_runtime = {
      schedule = function(callback)
        callback()
      end,
      timer_factory = function() end,
      tempdir_factory = function() end,
      remove_tree = function() end,
      realpath = function() end,
      process_factory = function() end,
    },
  })

  test.eq(4, service.retry.max_attempts)
  test.eq(25, service.retry.initial_delay_ms)
  test.eq(200, service.retry.max_delay_ms)
  local returned = service.defer(75, function() end)
  test.eq(75, observed.milliseconds)
  test.eq(token, returned)
end)

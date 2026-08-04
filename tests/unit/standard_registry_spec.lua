local test = require("tests.testlib")
local config_module = require("bilingua.config")
local registry_module = require("bilingua.registry")
local standard_registry = require("bilingua.standard_registry")

-- Preconditions: A fresh Registry has no extension factories. Prerequisites:
-- standard registration must remain lazy and may construct objects but must not
-- open Codex or create a process. Verification items: every implementation named
-- by the default config is registered, the default TranslationService resolves
-- its backend and both codecs by Registry ID, and repeated registration is safe.
test.it("registers and composes every standard extension exactly once", function()
  local registry = registry_module.new()
  local registered, registration_error = standard_registry.register(registry)
  test.eq(true, registered)
  test.eq(nil, registration_error)

  local config = config_module.defaults()
  local process_factory = function()
    error("construction must not start Codex")
  end
  local scheduler = {
    schedule = function(_, callback)
      callback()
    end,
    defer = function()
      return { cancel = function() end }
    end,
  }
  local context = {
    session_id = "session:standard",
    registry = registry,
    config = config,
    scheduler = scheduler,
    document_runtime = {
      markdown_available = function()
        return true
      end,
      analyze_markdown = function()
        return { capture_count = 0 }
      end,
    },
    warn = function(message)
      error("available Markdown runtime must not warn: " .. message)
    end,
    backend_runtime = {
      schedule = function(callback)
        callback()
      end,
      timer_factory = function()
        error("construction must not create a timer")
      end,
      tempdir_factory = function()
        error("construction must not create a directory")
      end,
      remove_tree = function()
        return true
      end,
      realpath = function(path)
        return path
      end,
      process_factory = process_factory,
    },
  }
  local plaintext = registry:get_document_adapter("plaintext")(config, context)
  local markdown = registry:get_document_adapter("markdown")(config, context)
  local tracker = registry:get_unit_tracker("hybrid")(config, context)
  local aligner = registry:get_aligner("generated_id")(config, context)
  local service = registry:get_translation_service("default")(config, context)

  test.eq("plaintext", plaintext.id)
  test.eq("markdown", markdown.id)
  test.eq("hybrid", tracker.id)
  test.eq("generated_id", aligner.id)
  test.eq("codex_app_server", service.backend.id)
  test.eq("initial_translation_json_v1", service.initial_codec.id)
  test.eq("semantic_patch_json_v1", service.patch_codec.id)
  test.eq("new", service.state)
  test.eq(process_factory, service.backend.process_factory)
  test.eq(nil, service.backend.configuration_error)

  local repeated, repeated_error = standard_registry.register(registry)
  test.eq(true, repeated)
  test.eq(nil, repeated_error)
end)

-- Preconditions: A resolved config has distinct nested Codex options, then its
-- compatibility mirror is deliberately changed before the factory is called.
-- Prerequisites: registry composition trusts translation.backends[backend_id],
-- copies it per construction, adds global timeout/ring size, and injects only
-- runtime fields not already supplied by the selected backend options.
-- Verification items: nested values beat the changed mirror, user runtime wins over
-- injection, no resource factory is called during construction, and mutation of one
-- backend instance cannot affect the next instance or source configuration.
test.it("resolves isolated backend options from the backend-specific table", function()
  local registry = registry_module.new()
  assert(standard_registry.register(registry))
  local user_schedule = function() end
  local config = assert(config_module.resolve({
    translation = {
      timeout_ms = 4321,
      backends = {
        codex_app_server = {
          command = { "nested-codex" },
          model = "nested-model",
          schedule = user_schedule,
        },
        llama_server = {
          model = "llama-model-must-not-leak",
        },
      },
    },
    debug = { ring_size = 37 },
  }))
  config.translation.backend_options.command = { "changed-mirror" }
  config.translation.backend_options.model = "changed-mirror-model"

  local resource_calls = 0
  local injected_schedule = function() end
  local context = {
    backend_runtime = {
      schedule = injected_schedule,
      timer_factory = function()
        resource_calls = resource_calls + 1
        error("construction must not create a timer")
      end,
      tempdir_factory = function()
        resource_calls = resource_calls + 1
        error("construction must not create a directory")
      end,
      process_factory = function()
        resource_calls = resource_calls + 1
        error("construction must not start a process")
      end,
      remove_tree = function()
        return true
      end,
      realpath = function(path)
        return path
      end,
    },
  }
  local factory = assert(registry:get_translation_backend("codex_app_server"))
  local first = factory(config, context)

  test.eq({ "nested-codex" }, first.command)
  test.eq("nested-model", first.configured_model)
  test.eq(user_schedule, first.schedule)
  test.eq(4321, first.turn_timeout_ms)
  test.eq(37, first.ring_size)
  test.eq(0, resource_calls)

  first.command[1] = "mutated-instance"
  local second = factory(config, context)
  test.eq({ "nested-codex" }, second.command)
  test.eq({ "nested-codex" }, config.translation.backends.codex_app_server.command)
  test.eq(0, resource_calls)
end)

-- Preconditions: A resolved llama configuration retains distinct built-in Codex
-- options and receives the real backend runtime ports through standard composition.
-- Prerequisites: both backend factories use the shared backend_options resolver;
-- llama construction creates a curl transport but starts no timer or process.
-- Verification items: both factories exist, default remains Codex, selected service
-- uses llama, option namespaces do not mix, global timeout is applied, all runtime
-- functions reach backend/transport by identity, and repeated registration stays safe.
test.it("registers and composes the llama backend without option or resource leakage", function()
  local registry = registry_module.new()
  assert(standard_registry.register(registry))
  test.eq("function", type(registry:get_translation_backend("codex_app_server")))
  test.eq("function", type(registry:get_translation_backend("llama_server")))
  test.eq("codex_app_server", config_module.defaults().translation.backend)

  local config = assert(config_module.resolve({
    translation = {
      backend = "llama_server",
      timeout_ms = 7654,
      backends = {
        codex_app_server = {
          command = { "codex-only-command" },
          model = "codex-only-model",
        },
        llama_server = {
          endpoint = "http://LOCALHOST:9090/",
          model = "llama-only-model",
          curl_command = { "curl-only-command", "--fixed" },
          request_timeout_ms = 0,
        },
      },
    },
  }))
  local resource_calls = 0
  local schedule = function() end
  local timer_factory = function()
    resource_calls = resource_calls + 1
    error("construction must not create a timer")
  end
  local process_factory = function()
    resource_calls = resource_calls + 1
    error("construction must not start curl or Codex")
  end
  local context = {
    session_id = "session:llama-registry",
    registry = registry,
    scheduler = {
      schedule = function(_, callback)
        callback()
      end,
      defer = function()
        return { cancel = function() end }
      end,
    },
    backend_runtime = {
      schedule = schedule,
      timer_factory = timer_factory,
      process_factory = process_factory,
      tempdir_factory = function()
        resource_calls = resource_calls + 1
        error("construction must not create a directory")
      end,
      remove_tree = function()
        return true
      end,
      realpath = function(path)
        return path
      end,
    },
  }

  local service = registry:get_translation_service("default")(config, context)
  local llama = service.backend
  test.eq("llama_server", llama.id)
  test.eq("http://localhost:9090", llama.endpoint)
  test.eq("llama-only-model", llama.configured_model)
  test.eq(7654, llama.request_timeout_ms)
  test.eq({ "curl-only-command", "--fixed" }, llama.transport.command)
  test.eq(schedule, llama.schedule)
  test.eq(timer_factory, llama.timer_factory)
  test.eq(schedule, llama.transport.schedule)
  test.eq(process_factory, llama.transport.process_factory)
  test.eq(nil, llama.command)
  test.eq(nil, llama.strict_isolation)
  test.eq(0, resource_calls)

  local codex_factory = assert(registry:get_translation_backend("codex_app_server"))
  local codex = codex_factory(config, context)
  test.eq("codex_app_server", codex.id)
  test.eq({ "codex-only-command" }, codex.command)
  test.eq("codex-only-model", codex.configured_model)
  test.eq(nil, codex.endpoint)
  test.eq(nil, codex.structured_output_mode)
  test.eq(0, resource_calls)

  local repeated, repeated_error = standard_registry.register(registry)
  test.eq(true, repeated)
  test.eq(nil, repeated_error)
end)

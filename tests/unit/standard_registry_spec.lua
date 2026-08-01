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

local test = require("tests.testlib")
local registry_module = require("bilingua.registry")
local session_module = require("bilingua.app.session")
local session_factory_module = require("bilingua.app.session_factory")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: A fresh extension registry contains all factories named by the
-- text route and default translation service. Prerequisites: Concrete dependencies
-- are resolved once in SessionFactory, every Port must advertise api_version=1 and
-- required methods, and Session must not require concrete adapters itself.
-- Verification items: a Session receives all selected instances and context, then
-- replacing one factory with an incompatible version causes E_INVALID_ARGUMENT
-- before a Session is returned.
test.it("resolves and contract-checks all session dependencies", function()
  local registry = registry_module.new()
  local received_sha256
  local injected_sha256 = function(value)
    return "digest:" .. value
  end
  assert(registry:register_document_adapter("plaintext", function(_, context)
    received_sha256 = context.sha256
    return plaintext.new()
  end))
  assert(registry:register_unit_tracker("hybrid", function()
    return hybrid.new()
  end))
  assert(registry:register_aligner("generated_id", function()
    return generated_id.new()
  end))
  assert(registry:register_translation_service("default", function()
    return fake_translation.new(function()
      error("not used by this construction test")
    end)
  end))
  local factory = session_factory_module.new({
    registry = registry,
    sha256 = injected_sha256,
    editor_factory = function()
      return fake_editor.new("Hello", "text")
    end,
  })
  local resolved = {
    source_language = "en",
    target_language = "ja",
    documents = {
      fallback_to_plaintext = true,
      routes = {
        text = { adapter = "plaintext", tracker = "hybrid", aligner = "generated_id" },
      },
    },
    translation = { service = "default" },
    limits = { max_document_bytes = 1024, max_units = 20, max_task_output_chars = 1024 },
    sync = { context_groups = 1 },
  }
  local session, err =
    factory:create({ source_buf = 9, source_window = 10, filetype = "text" }, resolved)

  test.eq(nil, err)
  test.eq("plaintext", session.document_adapter.id)
  test.eq("hybrid", session.unit_tracker.id)
  test.eq("generated_id", session.aligner.id)
  test.eq(9, session.source_buf)
  test.eq(true, received_sha256 == injected_sha256)

  assert(registry:register_aligner("generated_id", function()
    return { api_version = 2, id = "generated_id" }
  end, { replace = true }))
  local incompatible, incompatible_error =
    factory:create({ source_buf = 11, source_window = 12, filetype = "text" }, resolved)
  test.eq(nil, incompatible)
  test.eq("E_INVALID_ARGUMENT", incompatible_error.code)
end)

local function recovery_registry(translation_factory)
  local registry = registry_module.new()
  assert(registry:register_document_adapter("plaintext", function()
    return plaintext.new()
  end))
  assert(registry:register_unit_tracker("hybrid", function()
    return hybrid.new()
  end))
  assert(registry:register_aligner("generated_id", function()
    return generated_id.new()
  end))
  assert(registry:register_translation_service("default", translation_factory))
  return registry
end

local function factory_config(documents)
  return {
    source_language = "en",
    target_language = "ja",
    documents = documents or {
      fallback_to_plaintext = true,
      routes = {
        text = { adapter = "plaintext", tracker = "hybrid", aligner = "generated_id" },
      },
    },
    translation = { service = "default" },
    limits = { max_document_bytes = 1024, max_units = 20, max_task_output_chars = 1024 },
    sync = { context_groups = 1 },
  }
end

-- Preconditions: Each identified extension factory returns an otherwise valid
-- API-version-1 object whose id is empty. Prerequisites: DocumentAdapterPort,
-- UnitTrackerPort, and AlignerPort explicitly require stable non-empty IDs.
-- Verification items: SessionFactory rejects every such object with
-- E_INVALID_ARGUMENT before returning a Session.
test.it("rejects empty IDs on identified extension ports", function()
  local cases = {
    {
      register = "register_document_adapter",
      key = "plaintext",
      make = function()
        local instance = plaintext.new()
        instance.id = ""
        return instance
      end,
    },
    {
      register = "register_unit_tracker",
      key = "hybrid",
      make = function()
        local instance = hybrid.new()
        instance.id = ""
        return instance
      end,
    },
    {
      register = "register_aligner",
      key = "generated_id",
      make = function()
        local instance = generated_id.new()
        instance.id = ""
        return instance
      end,
    },
  }

  for _, case in ipairs(cases) do
    local registry = recovery_registry(function()
      return fake_translation.new(function()
        error("not submitted")
      end)
    end)
    assert(registry[case.register](registry, case.key, case.make, { replace = true }))
    local factory = session_factory_module.new({
      registry = registry,
      editor_factory = function()
        return fake_editor.new("Hello", "text")
      end,
    })

    local session, err =
      factory:create({ source_buf = 21, source_window = 22, filetype = "text" }, factory_config())

    test.eq(nil, session)
    test.eq("E_INVALID_ARGUMENT", err.code)
  end
end)

-- Preconditions: Editor construction succeeds, then a later registered component
-- factory raises before Session construction completes. Prerequisites: Factory
-- boundaries normalize exceptions and unwind already-owned resources in reverse
-- order. Verification items: create does not raise, returns E_INTERNAL naming the
-- failed component, and disposes the partially-created Editor exactly once.
test.it("unwinds partial resources when a component factory raises", function()
  local editor
  local registry = recovery_registry(function()
    error("service factory exploded")
  end)
  local factory = session_factory_module.new({
    registry = registry,
    editor_factory = function()
      editor = fake_editor.new("Hello", "text")
      return editor
    end,
  })

  local called, session, err = pcall(
    factory.create,
    factory,
    { source_buf = 31, source_window = 32, filetype = "text" },
    factory_config()
  )

  test.eq(true, called)
  test.eq(nil, session)
  test.eq("E_INTERNAL", err.code)
  test.eq("translation_service", err.details.component)
  test.eq(true, editor.disposed)
end)

-- Preconditions: The current filetype has no exact route but has a configured
-- alias to a canonical route, and plaintext fallback is disabled. Prerequisites:
-- exact matching has priority, then alias lookup supplies the complete adapter,
-- tracker, and aligner tuple. Verification items: Session construction succeeds
-- through the aliased route instead of returning E_UNSUPPORTED_FILETYPE.
test.it("resolves a filetype alias after exact route lookup", function()
  local registry = recovery_registry(function()
    return fake_translation.new(function()
      error("not submitted")
    end)
  end)
  local factory = session_factory_module.new({
    registry = registry,
    editor_factory = function()
      return fake_editor.new("Hello", "md")
    end,
  })
  local config = factory_config({
    fallback_to_plaintext = false,
    aliases = { md = "markdown" },
    routes = {
      markdown = { adapter = "plaintext", tracker = "hybrid", aligner = "generated_id" },
    },
  })

  local session, err =
    factory:create({ source_buf = 41, source_window = 42, filetype = "md" }, config)

  test.eq(nil, err)
  test.eq("plaintext", session.document_adapter.id)
end)

-- Preconditions: All five adapter/service instances satisfy their contracts, then
-- final Session construction raises unexpectedly. Prerequisites: SessionFactory still
-- owns the not-yet-returned Editor and TranslationService and must unwind both without
-- exposing a Lua exception. Verification items: create returns E_INTERNAL identifying
-- the Session component, closes the service, and disposes the Editor exactly once.
test.it("unwinds resources when final Session construction raises", function()
  local editor
  local service
  local registry = recovery_registry(function()
    service = fake_translation.new(function()
      error("not submitted")
    end)
    return service
  end)
  local factory = session_factory_module.new({
    registry = registry,
    editor_factory = function()
      editor = fake_editor.new("Hello", "text")
      return editor
    end,
  })
  local original_new = session_module.new
  local called
  local created
  local create_error
  local completed, failure = xpcall(function()
    session_module.new = function()
      error("Session constructor exploded")
    end
    called, created, create_error = pcall(
      factory.create,
      factory,
      { source_buf = 51, source_window = 52, filetype = "text" },
      factory_config()
    )
  end, debug.traceback)
  session_module.new = original_new

  assert(completed, failure)
  test.eq(true, called)
  test.eq(nil, created)
  test.eq("E_INTERNAL", create_error.code)
  test.eq("session", create_error.details.component)
  test.eq("closed", service.state)
  test.eq(true, editor.disposed)
end)

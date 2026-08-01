local test = require("tests.testlib")
local errors = require("bilingua.domain.error")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

local function initial_result(task)
  return {
    schema_version = 1,
    task_id = task.task_id,
    destination_side = "target",
    replacement_units = {
      {
        local_id = "initial:1",
        corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
        kind = "paragraph",
        content_text = "こんにちは",
        language = "ja",
      },
    },
    warnings = {},
    metadata = {},
  }
end

local function new_session(editor, translator, translator_factory)
  local session = session_module.new({
    id = "session:recovery",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    translator_factory = translator_factory,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 1024, max_units = 20, max_task_output_chars = 1024 },
      sync = {
        automatic = false,
        max_concurrency = 1,
        context_groups = 1,
        structural_changes = "auto_safe",
      },
      stop = { timeout_ms = 1000 },
    },
  })
  session.source_buf = 1
  session.target_buf = 2
  return session
end

-- Preconditions: A ready Session has a source-dirty group whose first manual
-- synchronization failed, while current buffers and revision remain valid.
-- Prerequisites: retry must clear runtime error state by recomputing dirtiness and
-- submit the current revision, not replay a stored response or old task.
-- Verification items: retry_current succeeds, emits a distinct task, applies its
-- result to target, clears last_error, and establishes a clean baseline.
test.it("retries the current failed mapping group at its latest revision", function()
  local editor = fake_editor.new("Hello", "text")
  local patch_attempts = 0
  local translator = fake_translation.new(function(task)
    if task.kind == "initial_translate" then
      return initial_result(task)
    end
    patch_attempts = patch_attempts + 1
    if patch_attempts == 1 then
      return nil, errors.new(errors.codes.BACKEND_UNAVAILABLE, "offline", true)
    end
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = "patch:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = "やあ",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local session = new_session(editor, translator)
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "Hi"
  editor.documents.source.version = editor.documents.source.version + 1
  editor.subscriptions.source({
    side = "source",
    version = editor.documents.source.version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = 2 } } },
    origin = "user",
    full_reload = false,
  })
  local first, first_error = session:sync_all()
  test.eq(nil, first)
  test.eq("E_BACKEND_UNAVAILABLE", first_error.code)
  editor.cursor_units.source = session.source_snapshot.order[1]

  local retried, retry_error = session:retry_current(1)

  test.eq(true, retried)
  test.eq(nil, retry_error)
  test.eq(3, #translator.submitted)
  test.eq("やあ", editor.documents.target.text)
  test.eq("clean", session.mapping_graph.groups["group:000001"].state)
  test.eq(nil, session.sync_engine.last_error)
end)

-- Preconditions: A ready but degraded Session has a factory capable of creating a
-- fresh TranslationService. Prerequisites: backend restart must not rebuild target
-- text, snapshots, or mapping IDs, and old queued work must be cancelled before the
-- new service becomes visible. Verification items: old service closes, new service
-- opens, Session and rebuilt SyncEngine share it, health returns healthy, and the
-- original mapping graph object remains active.
test.it("restarts the backend while preserving document state", function()
  local editor = fake_editor.new("Hello", "text")
  local old_service = fake_translation.new(function(task)
    return initial_result(task)
  end)
  local new_service = fake_translation.new(function()
    error("no translation should be submitted during restart")
  end)
  local factory_calls = 0
  local session = new_session(editor, old_service, function()
    factory_calls = factory_calls + 1
    return new_service
  end)
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  local graph = session.mapping_graph
  session.health = "degraded"
  session.last_error = errors.new(errors.codes.BACKEND_UNAVAILABLE, "process exited", true)

  local callback_ok
  local restarted, restart_error = session:restart_backend(function(ok, err)
    test.eq(nil, err)
    callback_ok = ok
  end)

  test.eq(true, restarted)
  test.eq(nil, restart_error)
  test.eq(true, callback_ok)
  test.eq(1, factory_calls)
  test.eq("closed", old_service.state)
  test.eq("open", new_service.state)
  test.eq(new_service, session.translator)
  test.eq(new_service, session.sync_engine.translator)
  test.eq(graph, session.mapping_graph)
  test.eq("healthy", session.health)
  test.eq(nil, session.last_error)
end)

-- Preconditions: Backend restart has disposed synchronization and is waiting for
-- the old service close callback when the user force-stops the Session.
-- Prerequisites: stop must settle the restart operation before disposing snapshots;
-- late restart callbacks are advisory only and cannot recreate a service or engine.
-- Verification items: restart reports E_SESSION_CLOSED, the replacement factory is
-- never called, and a late old-service close leaves the Session stopped/disposed.
test.it("keeps a force-stopped Session stopped after a late restart callback", function()
  local editor = fake_editor.new("Hello", "text")
  local old_service = fake_translation.new(function(task)
    return initial_result(task)
  end)
  local new_service = fake_translation.new(function()
    error("must not submit")
  end)
  local factory_calls = 0
  local session = new_session(editor, old_service, function()
    factory_calls = factory_calls + 1
    return new_service
  end)
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  local close_callbacks = {}
  old_service.close = function(self, callback)
    self.state = "closing"
    close_callbacks[#close_callbacks + 1] = callback
  end
  local restart_ok, restart_error
  assert(session:restart_backend(function(ok, err)
    restart_ok, restart_error = ok, err
  end))
  test.eq(true, session.backend_restarting)

  local stopped, stop_error = session:stop({ force = true })
  close_callbacks[1](true)
  if close_callbacks[2] then
    close_callbacks[2](true)
  end

  test.eq(true, stopped)
  test.eq(nil, stop_error)
  test.eq(nil, restart_ok)
  test.eq("E_SESSION_CLOSED", restart_error.code)
  test.eq(0, factory_calls)
  test.eq("stopped", session.state)
  test.eq("disposed", session.health)
  test.eq(nil, session.sync_engine)
end)

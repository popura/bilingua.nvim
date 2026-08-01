local test = require("tests.testlib")
local errors = require("bilingua.domain.error")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

local function translation_result(task, text)
  return {
    schema_version = 1,
    task_id = task.task_id,
    destination_side = "target",
    replacement_units = {
      {
        local_id = task.kind == "initial_translate" and "initial:1" or "patch:1",
        corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
        kind = "paragraph",
        content_text = text,
        language = "ja",
      },
    },
    warnings = {},
    metadata = {},
  }
end

local function new_session(editor, translator)
  local session = session_module.new({
    id = "session:runtime-health",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 1024, max_units = 20, max_task_output_chars = 1024 },
      sync = {
        automatic = false,
        debounce_ms = 1,
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

local function edit_source(editor, text)
  editor.documents.source.text = text
  editor.documents.source.version = editor.documents.source.version + 1
  editor.subscriptions.source({
    side = "source",
    version = editor.documents.source.version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = #text } } },
    origin = "user",
    full_reload = false,
  })
end

-- Preconditions: A ready Session receives a source edit and its TranslationService
-- returns a valid semantic patch synchronously. Prerequisites: runtime notifications
-- must cross the SyncEngine/Session boundary without exposing fragments, prompts, or
-- responses. Verification items: exactly one started and one completed event carry
-- only operation identifiers/state, share a task ID, and end with a healthy Session.
test.it("emits content-free runtime synchronization lifecycle events", function()
  local editor = fake_editor.new("Hello", "text")
  local translator = fake_translation.new(function(task)
    return translation_result(
      task,
      task.kind == "initial_translate" and "こんにちは" or "やあ"
    )
  end)
  local session = new_session(editor, translator)
  local events = {}
  session.on_event = function(event, data)
    events[#events + 1] = { event = event, data = data }
  end
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  edit_source(editor, "Hi")
  assert(session:sync_all())

  test.eq(2, #events)
  test.eq("BilinguaSyncStarted", events[1].event)
  test.eq("BilinguaSyncCompleted", events[2].event)
  test.eq("group:000001", events[1].data.group_id)
  test.eq(events[1].data.task_id, events[2].data.task_id)
  test.eq("syncing_source_to_target", events[1].data.state)
  test.eq("clean", events[2].data.state)
  test.eq(nil, events[1].data.text)
  test.eq(nil, events[2].data.result)
  test.eq(nil, events[2].data.error)
  test.eq("healthy", session.health)
end)

-- Preconditions: Automatic synchronization is enabled after startup and a runtime
-- patch fails with E_BACKEND_UNAVAILABLE. Prerequisites: the failed group must remain
-- dirty and later editor changes must still be recorded without repeatedly calling a
-- dead backend. Verification items: health becomes degraded, automatic sync is marked
-- paused in status, one content-free error event is emitted, and a second edit submits
-- no additional task until explicit backend recovery.
test.it("pauses automatic synchronization after a fatal backend failure", function()
  local editor = fake_editor.new("Hello", "text")
  local translator = fake_translation.new(function(task)
    if task.kind == "initial_translate" then
      return translation_result(task, "こんにちは")
    end
    return nil, errors.new(errors.codes.BACKEND_UNAVAILABLE, "backend process exited", true)
  end)
  local session = new_session(editor, translator)
  local events = {}
  session.on_event = function(event, data)
    events[#events + 1] = { event = event, data = data }
  end
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  session.config.sync.automatic = true

  edit_source(editor, "Hi")

  test.eq("degraded", session.health)
  test.eq(true, session.automatic_sync_paused)
  test.eq(false, session:status_snapshot().automatic_sync)
  test.eq(true, session:status_snapshot().automatic_sync_paused)
  test.eq("BilinguaError", events[#events].event)
  test.eq("E_BACKEND_UNAVAILABLE", events[#events].data.error_code)
  test.eq(nil, events[#events].data.error)
  test.eq(2, #translator.submitted)

  edit_source(editor, "Howdy")

  test.eq(2, #translator.submitted)
  test.eq(1, #session.pending_changes.source)
  test.eq("dirty_source", session.mapping_graph.groups["group:000001"].state)
end)

-- Preconditions: A ready Session has accepted one source edit, then the Translation
-- Service submit method raises before returning a handle or terminal callback.
-- Prerequisites: Port exceptions must be normalized at the application boundary and
-- cannot strand an inflight group. Verification items: sync returns E_INTERNAL, the
-- group returns to dirty_source with inflight IDs cleared, health degrades, and one
-- sanitized error event reports the normalized code.
test.it("normalizes a TranslationService submit exception without stranding a group", function()
  local editor = fake_editor.new("Hello", "text")
  local translator = fake_translation.new(function(task)
    return translation_result(task, "こんにちは")
  end)
  local session = new_session(editor, translator)
  local events = {}
  session.on_event = function(event, data)
    events[#events + 1] = { event = event, data = data }
  end
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  translator.submit = function()
    error("submit exploded")
  end
  edit_source(editor, "Hi")

  local synced, sync_error = session:sync_all()

  test.eq(nil, synced)
  test.eq("E_INTERNAL", sync_error.code)
  local group = session.mapping_graph.groups["group:000001"]
  test.eq("dirty_source", group.state)
  test.eq(nil, group.inflight_task_id)
  test.eq(nil, group.inflight_revision)
  test.eq("degraded", session.health)
  test.eq("BilinguaError", events[#events].event)
  test.eq("E_INTERNAL", events[#events].data.error_code)
end)
-- Preconditions: A source edit produced an invalid mapping group because the first
-- normalized patch violated the document adapter contract; the next backend result
-- is valid. Prerequisites: SyncAll promises to retry dirty and error groups, so it
-- must derive the current dirty direction from the baseline without requiring a new
-- editor event. Verification items: the first call reports validation and marks the
-- group invalid; the second call submits a fresh task, updates target text, and
-- restores the group to clean.
test.it("retries an invalid mapping group when synchronizing all", function()
  local editor = fake_editor.new("Hello", "text")
  local patch_attempts = 0
  local translator = fake_translation.new(function(task)
    if task.kind == "initial_translate" then
      return translation_result(task, "こんにちは")
    end
    patch_attempts = patch_attempts + 1
    local result = translation_result(task, patch_attempts == 1 and "不正" or "回復")
    if patch_attempts == 1 then
      result.replacement_units[1].kind = "heading"
    end
    return result
  end)
  local session = new_session(editor, translator)
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  edit_source(editor, "Hi")

  local first_sync, first_error = session:sync_all()

  test.eq(nil, first_sync)
  test.eq("E_VALIDATION", first_error.code)
  test.eq("invalid", session.mapping_graph.groups["group:000001"].state)

  local second_sync, second_error = session:sync_all()

  test.eq(true, second_sync)
  test.eq(nil, second_error)
  test.eq(2, patch_attempts)
  test.eq("回復", editor.documents.target.text)
  test.eq("clean", session.mapping_graph.groups["group:000001"].state)
end)

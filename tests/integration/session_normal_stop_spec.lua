local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local deferred_translation = require("tests.fakes.deferred_translation_service")
local fake_translation = require("tests.fakes.translation_service")

local function response(task)
  local initial = task.kind == "initial_translate"
  return {
    schema_version = 1,
    task_id = task.task_id,
    destination_side = initial and "target" or "source",
    replacement_units = {
      {
        local_id = initial and "initial:1" or "patch:1",
        corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
        kind = "paragraph",
        content_text = initial and "こんにちは" or "Hello!",
        language = initial and "ja" or "en",
      },
    },
    warnings = {},
    metadata = {},
  }
end

local function new_session(editor, translator, scheduler)
  return session_module.new({
    id = "session:normal-stop",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    scheduler = scheduler,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 1024, max_units = 20, max_task_output_chars = 1024 },
      sync = {
        automatic = false,
        debounce_ms = 700,
        max_concurrency = 1,
        context_groups = 1,
        structural_changes = "auto_safe",
      },
      stop = { sync_pending = true, timeout_ms = 1000 },
    },
  })
end

-- Preconditions: A ready Session has a target-only pending edit and its semantic
-- patch backend completes later. Prerequisites: safe stop must reject new edits,
-- synchronize Japanese work back to the source, and wait for accepted work before
-- closing owned resources. Verification items: stop enters stopping without an
-- early callback or disposal, completion applies the source edit, then closes the
-- service and target, reports success once, and cancels its timeout token.
test.it("waits for target-to-source synchronization before normal disposal", function()
  local editor = fake_editor.new("Hello", "text")
  local translator = deferred_translation.new(response, function(task)
    return task.kind ~= "initial_translate"
  end)
  local timer
  local scheduler = {
    defer = function(_, _, callback)
      timer = { callback = callback, cancelled = false }
      function timer:cancel()
        self.cancelled = true
      end
      return timer
    end,
  }
  local session = new_session(editor, translator, scheduler)
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.target.text = "こんにちは！"
  editor.documents.target.version = editor.documents.target.version + 1
  editor.subscriptions.target({
    side = "target",
    version = editor.documents.target.version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = 18 } } },
    origin = "user",
    full_reload = false,
  })

  local callback_count = 0
  local callback_ok
  local accepted, stop_error = session:stop({ force = false }, function(ok)
    callback_count = callback_count + 1
    callback_ok = ok
  end)
  test.eq(true, accepted)
  test.eq(nil, stop_error)
  test.eq("stopping", session.state)
  test.eq(0, callback_count)
  test.eq(false, editor.disposed)
  test.eq("open", translator.state)

  translator:complete_next()

  test.eq(1, callback_count)
  test.eq(true, callback_ok)
  test.eq("Hello!", editor.documents.source.text)
  test.eq("stopped", session.state)
  test.eq("closed", translator.state)
  test.eq(true, editor.disposed)
  test.eq(true, timer.cancelled)
end)

-- Preconditions: A ready Session has only a source-side pending edit.
-- Prerequisites: the Japanese buffer is ephemeral, so normal stop may discard a
-- source-to-target update while it must never discard target-to-source work.
-- Verification items: source text is preserved, no patch task is submitted, and
-- normal stop completes with all Session-owned resources disposed.
test.it("does not translate source-only work during normal stop", function()
  local editor = fake_editor.new("Hello", "text")
  local translator = fake_translation.new(response)
  local session = new_session(editor, translator)
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "Hello revised"
  editor.documents.source.version = editor.documents.source.version + 1
  editor.subscriptions.source({
    side = "source",
    version = editor.documents.source.version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = 13 } } },
    origin = "user",
    full_reload = false,
  })

  local stopped, stop_error = session:stop({ force = false })

  test.eq(true, stopped)
  test.eq(nil, stop_error)
  test.eq("Hello revised", editor.documents.source.text)
  test.eq(1, #translator.submitted)
  test.eq("stopped", session.state)
  test.eq(true, editor.disposed)
end)

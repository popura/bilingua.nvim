local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: A session completed initial translation and owns subscriptions,
-- snapshots, a mapping graph, a scratch target and an open translation service.
-- Prerequisites: Force stop may discard target-side work but must release every
-- plugin-owned resource and remain idempotent. Verification items: both calls
-- succeed, state is stopped, target and subscriptions are gone, the service is
-- closed, and Session no longer retains document or graph state.
test.it("force-stops a ready session and releases owned resources", function()
  local editor = fake_editor.new("Hello", "text")
  local translator = fake_translation.new(function(task)
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
  end)
  local session = session_module.new({
    id = "session:force-stop",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 1024, max_units = 20, max_task_output_chars = 1024 },
      sync = { context_groups = 1 },
    },
  })
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  local stopped, stop_error = session:stop({ force = true })

  test.eq(true, stopped)
  test.eq(nil, stop_error)
  test.eq(true, session:stop({ force = true }))
  test.eq("stopped", session.state)
  test.eq("closed", translator.state)
  test.eq(true, editor.disposed)
  test.eq(nil, editor.documents.target)
  test.eq(nil, editor.subscriptions.source)
  test.eq(nil, editor.subscriptions.target)
  test.eq(nil, session.mapping_graph)
  test.eq(nil, session.source_snapshot)
  test.eq(nil, session.target_snapshot)
end)

-- Preconditions: A ready Session owns a TranslationService whose close callback
-- never arrives. Prerequisites: force stop only needs to initiate backend close;
-- it must not wait to discard plugin-owned state, buffers, subscriptions, or graph.
-- Verification items: stop and its callback succeed synchronously, close is called
-- once, Session reaches stopped, and Editor resources are disposed immediately.
test.it("force-stops even when translation close never calls back", function()
  local editor = fake_editor.new("Hello", "text")
  local translator = fake_translation.new(function(task)
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
  end)
  local close_calls = 0
  translator.close = function(self)
    close_calls = close_calls + 1
    self.state = "closing"
  end
  local session = session_module.new({
    id = "session:force-stop-hanging-close",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 1024, max_units = 20, max_task_output_chars = 1024 },
      sync = { context_groups = 1 },
      stop = { timeout_ms = 1000 },
    },
  })
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  local callback_ok

  local stopped, stop_error = session:stop({ force = true }, function(ok)
    callback_ok = ok
  end)

  test.eq(true, stopped)
  test.eq(nil, stop_error)
  test.eq(true, callback_ok)
  test.eq(1, close_calls)
  test.eq("stopped", session.state)
  test.eq(true, editor.disposed)
  test.eq(nil, session.mapping_graph)
end)

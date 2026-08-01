local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: Source validation fails before target creation, and both cleanup
-- ports raise when Session attempts to close/dispose them. Prerequisites: cleanup is
-- best-effort and secondary exceptions cannot replace the original normalized start
-- error or suppress completion. Verification items: start itself does not raise, both
-- cleanup methods are attempted once, callback receives E_DOCUMENT_TOO_LARGE, and
-- Session remains failed/degraded with diagnostic cleanup errors retained internally.
test.it("settles start failure even when cleanup ports raise", function()
  local editor = fake_editor.new("oversized", "text")
  local translator = fake_translation.new(function()
    error("not submitted")
  end)
  local close_calls = 0
  local dispose_calls = 0
  translator.close = function()
    close_calls = close_calls + 1
    error("close exploded")
  end
  editor.dispose = function()
    dispose_calls = dispose_calls + 1
    error("dispose exploded")
  end
  local session = session_module.new({
    id = "session:start-cleanup",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = {
        max_document_bytes = 2,
        max_units = 20,
        max_task_output_chars = 1024,
      },
      sync = { max_concurrency = 1, context_groups = 1 },
    },
  })
  local callback_error
  local called, raised = pcall(session.start, session, function(ok, err)
    test.eq(nil, ok)
    callback_error = err
  end)

  test.eq(true, called)
  test.eq(nil, raised)
  test.eq("E_DOCUMENT_TOO_LARGE", callback_error.code)
  test.eq(1, close_calls)
  test.eq(1, dispose_calls)
  test.eq("failed", session.state)
  test.eq("degraded", session.health)
  test.eq("E_INTERNAL", session.close_error.code)
  test.eq("E_INTERNAL", session.dispose_error.code)
end)

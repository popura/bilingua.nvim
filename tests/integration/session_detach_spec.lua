local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: A ready Session owns both buffer subscriptions when the target
-- buffer reports an unrecoverable detach. Prerequisites: direct target deletion is
-- equivalent to force disposal and must not attempt to preserve dirty work.
-- Verification items: Session and backend stop, target resources are disposed,
-- no semantic patch is submitted, and the autonomous lifecycle callback identifies
-- the detached side exactly once.
test.it("force-disposes a Session when an owned buffer detaches", function()
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
    id = "session:detach",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 1024, max_units = 20, max_task_output_chars = 1024 },
      sync = { automatic = false, context_groups = 1 },
      stop = { timeout_ms = 1000 },
    },
  })
  local callback_count = 0
  local detached_side
  session.on_auto_dispose = function(_, side)
    callback_count = callback_count + 1
    detached_side = side
  end
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.subscriptions.target({
    side = "target",
    version = -1,
    ranges = {},
    origin = "unknown",
    full_reload = true,
    detached = true,
  })

  test.eq("stopped", session.state)
  test.eq("closed", translator.state)
  test.eq(true, editor.disposed)
  test.eq(1, #translator.submitted)
  test.eq(1, callback_count)
  test.eq("target", detached_side)
end)

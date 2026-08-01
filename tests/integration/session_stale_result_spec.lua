local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local deferred_translation = require("tests.fakes.deferred_translation_service")

-- Preconditions: A source-to-target patch is in flight when the source unit is
-- edited again, and the first backend response subsequently arrives.
-- Prerequisites: Correctness depends on revision and EditorPort version checks,
-- never on cancellation success. Verification items: the first result is not
-- applied or surfaced as an error, a new explicit sync uses the newest text, and
-- only the second result establishes a clean baseline.
test.it("discards a stale patch and synchronizes the latest revision", function()
  local editor = fake_editor.new("A", "text")
  local translator = deferred_translation.new(function(task)
    if task.kind == "initial_translate" then
      return {
        schema_version = 1,
        task_id = task.task_id,
        destination_side = "target",
        replacement_units = {
          {
            local_id = "initial:1",
            corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
            kind = "paragraph",
            content_text = "甲",
            language = "ja",
          },
        },
        warnings = {},
        metadata = {},
      }
    end
    local latest = task.edited_after.units[1].content_text
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = "patch:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = latest == "A2" and "甲二" or "甲一",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end, function(task)
    return task.kind == "propagate_edit"
  end)
  local session = session_module.new({
    id = "session:stale",
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
  local error_events = 0
  session.on_event = function(event)
    if event == "BilinguaError" then
      error_events = error_events + 1
    end
  end
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "A1"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = 2 } } },
    origin = "user",
    full_reload = false,
  })
  test.eq(true, session:sync_all())

  editor.documents.source.text = "A2"
  editor.documents.source.version = 3
  editor.subscriptions.source({
    side = "source",
    version = 3,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = 2 } } },
    origin = "user",
    full_reload = false,
  })
  translator:complete_next()

  test.eq("甲", editor.documents.target.text)
  test.eq("dirty_source", session.mapping_graph.groups["group:000001"].state)
  test.eq(nil, session.sync_engine.last_error)
  test.eq(0, error_events)
  test.eq(true, session:sync_all())
  test.eq("A2", translator.submitted[3].edited_after.units[1].content_text)
  translator:complete_next()

  test.eq("甲二", editor.documents.target.text)
  test.eq("clean", session.mapping_graph.groups["group:000001"].state)
  test.eq(0, error_events)
end)

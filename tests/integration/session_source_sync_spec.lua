local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: A ready session has baseline pairs (Hello, こんにちは) and
-- (World, 世界); the user changes only the first source paragraph.
-- Prerequisites: Explicit sync reparses the changed side, reconciles stable unit
-- IDs, creates a semantic patch from baseline/edited/destination fragments, and
-- applies through EditorPort with a plugin origin. Verification items: only the
-- matching target paragraph changes, the task carries the baseline triple, the
-- new actual fragments become the clean baseline, and no target user change is
-- queued from the programmatic apply.
test.it("propagates one source edit to its target group", function()
  local editor = fake_editor.new("Hello\n\nWorld", "text")
  local translator = fake_translation.new(function(task)
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
            content_text = "こんにちは",
            language = "ja",
          },
          {
            local_id = "initial:2",
            corresponds_to_edited_unit_ids = { task.edited_after.units[2].unit_id },
            kind = "paragraph",
            content_text = "世界",
            language = "ja",
          },
        },
        warnings = {},
        metadata = {},
      }
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
          content_text = "こんにちは！",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local session = session_module.new({
    id = "session:source-sync",
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

  editor.documents.source.text = "Hello there\n\nWorld"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = {
      { start = { row = 0, col = 0 }, finish = { row = 0, col = 11 } },
    },
    origin = "user",
    full_reload = false,
  })
  local synced, sync_error = session:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq("こんにちは！\n\n世界", editor.documents.target.text)
  test.eq(2, #translator.submitted)
  local task = translator.submitted[2]
  test.eq("propagate_edit", task.kind)
  test.eq("source_to_target", task.direction)
  test.eq("Hello", task.edited_before.units[1].content_text)
  test.eq("Hello there", task.edited_after.units[1].content_text)
  test.eq("こんにちは", task.destination_before.units[1].content_text)
  local group = session.mapping_graph.groups["group:000001"]
  test.eq("Hello there", group.baseline.source.units[1].content_text)
  test.eq("こんにちは！", group.baseline.target.units[1].content_text)
  test.eq("clean", group.state)
  test.eq({}, session.pending_changes.target)
  test.eq("bilingua-sync", editor.last_origin)
end)

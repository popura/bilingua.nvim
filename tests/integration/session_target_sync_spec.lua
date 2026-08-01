local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: A ready session has baseline pair (Hello, こんにちは), and the
-- user changes only the Japanese paragraph. Prerequisites: Direction is derived
-- from the dirty side; target-to-source uses the same revision and validation
-- gates as source-to-target. Verification items: the source paragraph changes,
-- the semantic task carries target before/after and source baseline fragments,
-- and the applied actual pair becomes clean without changing the target text.
test.it("propagates one Japanese edit back to its source group", function()
  local editor = fake_editor.new("Hello", "text")
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
        },
        warnings = {},
        metadata = {},
      }
    end
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "source",
      replacement_units = {
        {
          local_id = "patch:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = "Hello!",
          language = "en",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local session = session_module.new({
    id = "session:target-sync",
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

  editor.documents.target.text = "こんにちは！"
  editor.documents.target.version = editor.documents.target.version + 1
  editor.subscriptions.target({
    side = "target",
    version = editor.documents.target.version,
    ranges = {
      { start = { row = 0, col = 0 }, finish = { row = 0, col = 18 } },
    },
    origin = "user",
    full_reload = false,
  })
  local synced, sync_error = session:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq("Hello!", editor.documents.source.text)
  test.eq("こんにちは！", editor.documents.target.text)
  local task = translator.submitted[2]
  test.eq("target_to_source", task.direction)
  test.eq("こんにちは", task.edited_before.units[1].content_text)
  test.eq("こんにちは！", task.edited_after.units[1].content_text)
  test.eq("Hello", task.destination_before.units[1].content_text)
  test.eq("clean", session.mapping_graph.groups["group:000001"].state)
end)

local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: Both sides of one clean mapping group are edited before either
-- edit is synchronized. Prerequisites: Dirty state is computed against the same
-- baseline pair, and automatic synchronization must never infer a merge when both
-- sides differ. Verification items: the group becomes conflict, no patch task is
-- submitted, both user edits remain unchanged, and one content-free conflict event
-- identifies the affected group.
test.it("marks simultaneous source and target edits as a conflict", function()
  local editor = fake_editor.new("Hello", "text")
  local translator = fake_translation.new(function(task)
    if task.kind ~= "initial_translate" then
      error("a conflict must not submit an automatic patch task")
    end
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
    id = "session:conflict",
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
  local events = {}
  session.on_event = function(event, data)
    events[#events + 1] = { event = event, data = data }
  end
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "Hello source"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = 12 } } },
    origin = "user",
    full_reload = false,
  })
  editor.documents.target.text = "こんにちは target"
  editor.documents.target.version = editor.documents.target.version + 1
  editor.subscriptions.target({
    side = "target",
    version = editor.documents.target.version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = 22 } } },
    origin = "user",
    full_reload = false,
  })

  test.eq(true, session:sync_all())
  test.eq("conflict", session.mapping_graph.groups["group:000001"].state)
  test.eq(1, #translator.submitted)
  test.eq("Hello source", editor.documents.source.text)
  test.eq("こんにちは target", editor.documents.target.text)
  test.eq(1, #events)
  test.eq("BilinguaConflict", events[1].event)
  test.eq("group:000001", events[1].data.group_id)
  test.eq("E_CONFLICT", events[1].data.error_code)
  test.eq(nil, events[1].data.text)
end)

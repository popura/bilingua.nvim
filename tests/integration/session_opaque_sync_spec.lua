local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local markdown = require("bilingua.adapters.document.markdown")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: A ready Markdown Session has a mirrored YAML front matter group
-- and a translated heading group. Prerequisites: opaque raw bytes are owned by the
-- DocumentAdapter and must never enter a TranslationTask. Verification items: a
-- front matter edit is copied exactly to the target with guarded validation, the
-- translation service receives no additional task, unrelated translated Markdown
-- remains unchanged, and the mirror group establishes a new clean baseline.
test.it("mirrors an edited opaque Markdown group without calling translation", function()
  local source = "---\ntitle: Old\n---\n\n# Hello\n"
  local editor = fake_editor.new(source, "markdown")
  local translator = fake_translation.new(function(task)
    test.eq(1, #task.edited_after.units)
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = "heading:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "heading",
          content_text = "こんにちは",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local active = session_module.new({
    id = "session:opaque-sync",
    editor = editor,
    document_adapter = markdown.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 4096, max_units = 20, max_task_output_chars = 4096 },
      sync = {
        automatic = false,
        max_concurrency = 1,
        context_groups = 1,
        structural_changes = "auto_safe",
      },
    },
  })
  active:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "---\ntitle: New\n---\n\n# Hello\n"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 1, col = 7 }, finish = { row = 1, col = 10 } } },
    origin = "user",
    full_reload = false,
  })
  local synced, sync_error = active:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq(1, #translator.submitted)
  test.eq("---\ntitle: New\n---\n\n# こんにちは\n", editor.documents.target.text)
  local mirror = active.mapping_graph.groups[active.mapping_graph.order[1]]
  test.eq("mirror", mirror.metadata.mode)
  test.eq("clean", mirror.state)
end)

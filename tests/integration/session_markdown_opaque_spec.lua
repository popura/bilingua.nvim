local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local markdown = require("bilingua.adapters.document.markdown")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: A Markdown source contains YAML front matter, one heading, and a
-- fenced code block. Prerequisites: Opaque units remain in construction seeds but
-- must never enter TranslationTask.edited_after. Verification items: the service
-- receives only the heading, opaque bytes are mirrored exactly, all three blocks
-- receive mapping groups, and opaque groups are explicitly marked mirror mode.
test.it("excludes opaque Markdown units from initial translation and mirrors them", function()
  local source_text = "---\ntitle: Secret\n---\n\n# Hello\n\n```sh\necho private\n```\n"
  local editor = fake_editor.new(source_text, "markdown")
  local translator = fake_translation.new(function(task)
    test.eq(1, #task.edited_after.units)
    test.eq("heading", task.edited_after.units[1].kind)
    test.eq(nil, task.edited_after.units[1].raw_text)
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
    id = "session:markdown-opaque",
    editor = editor,
    document_adapter = markdown.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = {
        max_document_bytes = 4096,
        max_units = 50,
        max_task_output_chars = 4096,
        initial_batch_chars = 100,
        initial_batch_units = 8,
      },
      sync = { max_concurrency = 1, context_groups = 1, structural_changes = "auto_safe" },
    },
  })
  local started, start_error
  active:start(function(ok, err)
    started, start_error = ok, err
  end)

  test.eq(true, started)
  test.eq(nil, start_error)
  test.eq(true, editor.documents.target.text:find("---\ntitle: Secret\n---", 1, true) ~= nil)
  test.eq(true, editor.documents.target.text:find("# こんにちは", 1, true) ~= nil)
  test.eq(true, editor.documents.target.text:find("```sh\necho private\n```", 1, true) ~= nil)
  test.eq(3, #active.mapping_graph.order)
  test.eq("mirror", active.mapping_graph.groups[active.mapping_graph.order[1]].metadata.mode)
  test.eq("mirror", active.mapping_graph.groups[active.mapping_graph.order[3]].metadata.mode)
end)

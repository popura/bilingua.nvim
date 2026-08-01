local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: Auto-detected source units are split into separate one-unit
-- batches; four English characters and one French character make English exactly
-- 80 percent by UTF-8 codepoint weight. Prerequisites: batch-local codec metadata
-- must be combined by unit ID before baseline construction. Verification items:
-- each source unit records its own detected language, the document language is en
-- under the 80-percent rule, and baselines inherit the finalized languages.
test.it("aggregates source language detection across initial batches", function()
  local editor = fake_editor.new("aaaa\n\nb", "text")
  local translator = fake_translation.new(function(task)
    local unit = task.edited_after.units[1]
    local detected = unit.content_text == "aaaa" and "en" or "fr"
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = task.task_id .. ":1",
          corresponds_to_edited_unit_ids = { unit.unit_id },
          kind = "paragraph",
          content_text = "訳" .. unit.content_text,
          language = "ja",
        },
      },
      warnings = {},
      metadata = { source_languages = { [unit.unit_id] = detected } },
    }
  end)
  local active = session_module.new({
    id = "session:language",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "auto",
      target_language = "ja",
      limits = {
        max_document_bytes = 4096,
        max_units = 20,
        max_task_output_chars = 4096,
        initial_batch_chars = 100,
        initial_batch_units = 1,
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
  test.eq(2, #translator.submitted)
  test.eq("en", active.source_snapshot.language)
  test.eq("en", active.source_snapshot.units[active.source_snapshot.order[1]].language)
  test.eq("fr", active.source_snapshot.units[active.source_snapshot.order[2]].language)
  test.eq("en", active.mapping_graph.groups[active.mapping_graph.order[1]].baseline.source.language)
end)

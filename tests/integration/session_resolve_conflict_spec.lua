local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: One mapping group enters conflict twice because both source and
-- Japanese text differ from each current baseline. Prerequisites: Conflict
-- resolution requires an explicit authoritative side and treats the other current
-- fragment as replaceable; no inferred merge is allowed. Verification items:
-- UseSource submits resolve_conflict, preserves the current source, replaces the
-- Japanese text; UseJapanese then preserves Japanese and replaces the source.
test.it("resolves conflicts after choosing either authoritative side", function()
  local editor = fake_editor.new("Original", "text")
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
            content_text = "原文",
            language = "ja",
          },
        },
        warnings = {},
        metadata = {},
      }
    end
    local japanese_authoritative = task.edited_side == "target"
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = japanese_authoritative and "source" or "target",
      replacement_units = {
        {
          local_id = "resolved:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = japanese_authoritative and "Use Japanese" or "原文を採用",
          language = japanese_authoritative and "en" or "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local session = session_module.new({
    id = "session:resolve",
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

  editor.documents.source.text = "Use source"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = 10 } } },
    origin = "user",
    full_reload = false,
  })
  editor.documents.target.text = "日本語も変更"
  editor.documents.target.version = editor.documents.target.version + 1
  editor.subscriptions.target({
    side = "target",
    version = editor.documents.target.version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = 18 } } },
    origin = "user",
    full_reload = false,
  })
  assert(session:sync_all())

  local resolved, resolve_error = session:use_source("group:000001")

  test.eq(true, resolved)
  test.eq(nil, resolve_error)
  test.eq("Use source", editor.documents.source.text)
  test.eq("原文を採用", editor.documents.target.text)
  local task = translator.submitted[2]
  test.eq("resolve_conflict", task.kind)
  test.eq("source", task.edited_side)
  test.eq("日本語も変更", task.destination_before.units[1].content_text)
  test.eq("clean", session.mapping_graph.groups["group:000001"].state)

  editor.documents.source.text = "Source changed again"
  editor.documents.source.version = editor.documents.source.version + 1
  editor.subscriptions.source({
    side = "source",
    version = editor.documents.source.version,
    ranges = {
      { start = { row = 0, col = 0 }, finish = { row = 0, col = #"Source changed again" } },
    },
    origin = "user",
    full_reload = false,
  })
  editor.documents.target.text = "日本語を採用"
  editor.documents.target.version = editor.documents.target.version + 1
  editor.subscriptions.target({
    side = "target",
    version = editor.documents.target.version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = #"日本語を採用" } } },
    origin = "user",
    full_reload = false,
  })
  assert(session:sync_all())

  local japanese_resolved, japanese_error = session:use_japanese("group:000001")

  test.eq(true, japanese_resolved)
  test.eq(nil, japanese_error)
  test.eq("Use Japanese", editor.documents.source.text)
  test.eq("日本語を採用", editor.documents.target.text)
  local japanese_task = translator.submitted[3]
  test.eq("resolve_conflict", japanese_task.kind)
  test.eq("target", japanese_task.edited_side)
  test.eq("Source changed again", japanese_task.destination_before.units[1].content_text)
  test.eq("clean", session.mapping_graph.groups["group:000001"].state)
end)

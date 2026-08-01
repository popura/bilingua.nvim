local test = require("tests.testlib")
local errors = require("bilingua.domain.error")
local session_module = require("bilingua.app.session")
local markdown = require("bilingua.adapters.document.markdown")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: A ready Markdown Session initially contains one translated heading,
-- then the user inserts a complete fenced code block after it. Prerequisites: newly
-- aligned opaque units must become provisional mirror groups and must never enter a
-- TranslationTask. Verification items: synchronization succeeds without a second
-- service submission, copies the exact fenced bytes with separators, and leaves the
-- new group clean with explicit mirror metadata.
test.it("mirrors a newly inserted opaque Markdown block without translation", function()
  local editor = fake_editor.new("# Hello\n", "markdown")
  local translator = fake_translation.new(function(task)
    if task.kind ~= "initial_translate" then
      return nil, errors.new(errors.codes.TRANSLATION, "opaque content reached translator", false)
    end
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
  local session = session_module.new({
    id = "session:opaque-insertion",
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
        max_units = 20,
        max_task_output_chars = 4096,
        initial_batch_chars = 100,
        initial_batch_units = 8,
      },
      sync = {
        automatic = false,
        max_concurrency = 1,
        context_groups = 1,
        structural_changes = "auto_safe",
      },
    },
  })
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "# Hello\n\n```sh\necho private\n```\n"
  editor.documents.source.version = editor.documents.source.version + 1
  editor.subscriptions.source({
    side = "source",
    version = editor.documents.source.version,
    ranges = { { start = { row = 1, col = 0 }, finish = { row = 4, col = 0 } } },
    origin = "user",
    full_reload = false,
  })

  local synced, sync_error = session:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq(1, #translator.submitted)
  test.eq("# こんにちは\n\n```sh\necho private\n```\n", editor.documents.target.text)
  local inserted = session.mapping_graph.groups[session.mapping_graph.order[2]]
  test.eq("mirror", inserted.metadata.mode)
  test.eq("clean", inserted.state)
end)

-- Preconditions: A clean Markdown Session has one translated heading followed by
-- one mirrored fenced code block. Prerequisites: Removing opaque content is handled
-- entirely by DocumentAdapter mirror edits and may make its mapping group empty.
-- Verification items: deletion submits no translation task, removes the block and
-- its separator byte-for-byte, removes the empty group, and leaves the heading clean.
test.it("mirrors deletion of an opaque Markdown block without translation", function()
  local source = "# Hello\n\n```sh\necho private\n```\n"
  local editor = fake_editor.new(source, "markdown")
  local translator = fake_translation.new(function(task)
    if task.kind ~= "initial_translate" then
      return nil, errors.new(errors.codes.TRANSLATION, "opaque content reached translator", false)
    end
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
    id = "session:opaque-deletion",
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
        max_units = 20,
        max_task_output_chars = 4096,
        initial_batch_chars = 100,
        initial_batch_units = 8,
      },
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

  editor.documents.source.text = "# Hello\n"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 1, col = 0 }, finish = { row = 5, col = 0 } } },
    origin = "user",
    full_reload = false,
  })
  local synced, sync_error = active:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq(1, #translator.submitted)
  test.eq("# こんにちは\n", editor.documents.target.text)
  test.eq(1, #active.mapping_graph.order)
  test.eq("clean", active.mapping_graph.groups[active.mapping_graph.order[1]].state)
end)

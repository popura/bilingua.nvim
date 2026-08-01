local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

local function result_for(task, content)
  return {
    schema_version = 1,
    task_id = task.task_id,
    destination_side = "target",
    replacement_units = {
      {
        local_id = "result:1",
        corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
        kind = "paragraph",
        content_text = content,
        language = "ja",
      },
    },
    warnings = {},
    metadata = {},
  }
end

local function new_session(editor, translator, maximum_bytes, maximum_units)
  return session_module.new({
    id = "session:limits",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = {
        max_document_bytes = maximum_bytes,
        max_units = maximum_units,
        max_task_output_chars = 1000,
        initial_batch_chars = 1000,
        initial_batch_units = 20,
      },
      sync = { automatic = false, context_groups = 1, max_concurrency = 1 },
    },
  })
end

local function publish_source_change(editor, text)
  editor.documents.source.text = text
  editor.documents.source.version = editor.documents.source.version + 1
  editor.subscriptions.source({
    side = "source",
    version = editor.documents.source.version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = #text } } },
    origin = "user",
    full_reload = false,
  })
end

-- Preconditions: A ready Session is within its byte limit, then the user expands
-- the source beyond max_document_bytes. Prerequisites: every change flush reads
-- and validates the complete current document before parsing or mutating snapshots.
-- Verification items: sync returns E_DOCUMENT_TOO_LARGE, submits no patch, keeps
-- the previous snapshot, and leaves the target unchanged.
test.it("rejects an oversized source edit before runtime parsing", function()
  local editor = fake_editor.new("Hi", "text")
  local translator = fake_translation.new(function(task)
    if task.kind == "initial_translate" then
      return result_for(task, "やあ")
    end
    error("oversized source must not be submitted")
  end)
  local session = new_session(editor, translator, 8, 10)
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  publish_source_change(editor, "123456789")

  local synced, err = session:sync_all()

  test.eq(nil, synced)
  test.eq("E_DOCUMENT_TOO_LARGE", err.code)
  test.eq(1, #translator.submitted)
  test.eq("Hi", session.source_snapshot.units[session.source_snapshot.order[1]].content_text)
  test.eq("やあ", editor.documents.target.text)
end)

-- Preconditions: A ready one-unit Session receives an edit that splits the source
-- into two units while remaining below the byte limit. Prerequisites: max_units is
-- checked after parsing but before tracker, graph, or baseline state is published.
-- Verification items: synchronization returns E_DOCUMENT_TOO_LARGE, no patch is
-- submitted, and the previous one-unit snapshot remains authoritative.
test.it("rejects a runtime edit that exceeds the unit limit", function()
  local editor = fake_editor.new("A", "text")
  local translator = fake_translation.new(function(task)
    if task.kind == "initial_translate" then
      return result_for(task, "あ")
    end
    error("oversized unit set must not be submitted")
  end)
  local session = new_session(editor, translator, 1024, 1)
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  publish_source_change(editor, "A\n\nB")

  local synced, err = session:sync_all()

  test.eq(nil, synced)
  test.eq("E_DOCUMENT_TOO_LARGE", err.code)
  test.eq(1, #session.source_snapshot.order)
  test.eq(1, #translator.submitted)
end)

-- Preconditions: The source fits configured limits but the initial model result
-- would create a target larger than max_document_bytes. Prerequisites: initial
-- target text is size-checked before EditorPort apply. Verification items: startup
-- fails with E_DOCUMENT_TOO_LARGE, releases its target resources, and never reaches
-- ready with a partially initialized mapping graph.
test.it("rejects an oversized initial target before applying it", function()
  local editor = fake_editor.new("Hi", "text")
  local translator = fake_translation.new(function(task)
    return result_for(task, "日本語")
  end)
  local session = new_session(editor, translator, 8, 10)
  local started, start_error

  session:start(function(ok, err)
    started, start_error = ok, err
  end)

  test.eq(nil, started)
  test.eq("E_DOCUMENT_TOO_LARGE", start_error.code)
  test.eq("failed", session.state)
  test.eq(true, editor.disposed)
  test.eq(nil, session.mapping_graph)
end)

-- Preconditions: A source patch is valid but its translated replacement would
-- make the complete target exceed max_document_bytes. Prerequisites: SyncEngine
-- computes the virtual destination before calling EditorPort. Verification items:
-- the patch returns E_DOCUMENT_TOO_LARGE, target text/version remain unchanged,
-- and no oversized partial result appears in the scratch document.
test.it("rejects an oversized patch before destination apply", function()
  local editor = fake_editor.new("Hello", "text")
  local translator = fake_translation.new(function(task)
    if task.kind == "initial_translate" then
      return result_for(task, "やあ")
    end
    return result_for(task, "これは長すぎる")
  end)
  local session = new_session(editor, translator, 12, 10)
  session:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  publish_source_change(editor, "Hello!")
  local target_version = editor.documents.target.version

  local synced, err = session:sync_all()

  test.eq(nil, synced)
  test.eq("E_DOCUMENT_TOO_LARGE", err.code)
  test.eq("やあ", editor.documents.target.text)
  test.eq(target_version, editor.documents.target.version)
end)

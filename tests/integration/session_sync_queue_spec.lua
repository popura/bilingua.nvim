local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local deferred_translation = require("tests.fakes.deferred_translation_service")

local function config(maximum)
  return {
    source_language = "en",
    target_language = "ja",
    limits = {
      max_document_bytes = 4096,
      max_units = 20,
      max_task_output_chars = 4096,
      initial_batch_chars = 1000,
      initial_batch_units = 32,
    },
    sync = {
      automatic = false,
      debounce_ms = 20,
      max_concurrency = maximum,
      context_groups = 1,
      structural_changes = "auto_safe",
    },
  }
end

local function responder(task)
  local replacements = {}
  for index, unit in ipairs(task.edited_after.units) do
    replacements[index] = {
      local_id = task.task_id .. ":" .. index,
      corresponds_to_edited_unit_ids = { unit.unit_id },
      kind = "paragraph",
      content_text = (task.kind == "initial_translate" and "初" or "訳") .. unit.content_text,
      language = "ja",
    }
  end
  return {
    schema_version = 1,
    task_id = task.task_id,
    destination_side = "target",
    replacement_units = replacements,
    warnings = {},
    metadata = {},
  }
end

local function start(source, maximum)
  local editor = fake_editor.new(source, "text")
  local translator = deferred_translation.new(responder, function(task)
    return task.kind ~= "initial_translate"
  end)
  local active = session_module.new({
    id = "session:sync-queue",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = config(maximum),
  })
  active:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  return active, editor, translator
end

local function change(editor, text, version)
  editor.documents.source.text = text
  editor.documents.source.version = version
  editor.subscriptions.source({
    side = "source",
    version = version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 4, col = 2 } } },
    origin = "user",
    full_reload = false,
  })
end

-- Preconditions: Three distinct groups become dirty together and the configured
-- maximum concurrency is two. Prerequisites: initial translation is complete and
-- does not occupy the normal synchronization queue. Verification items: only two
-- patch tasks start, one completion opens exactly one slot for the third, and the
-- logical active count never exceeds two.
test.it("enforces max_concurrency across dirty mapping groups", function()
  local active, editor, translator = start("A\n\nB\n\nC", 2)
  change(editor, "A1\n\nB1\n\nC1", 2)

  test.eq(true, active:sync_all())
  test.eq(3, #translator.submitted)
  test.eq(2, active.sync_engine.task_queue:status().active)
  test.eq(1, active.sync_engine.task_queue:status().pending)

  translator:complete_task(translator.submitted[2].task_id)
  test.eq(4, #translator.submitted)
  test.eq(2, active.sync_engine.task_queue:status().active)
  test.eq(0, active.sync_engine.task_queue:status().pending)
end)

-- Preconditions: A source patch for one group is active when that group is edited
-- again and explicitly synchronized. Prerequisites: backend cancellation cannot
-- be trusted, so the old fake still delivers its callback. Verification items:
-- the old handle is cancelled, a newer task starts, late old completion neither
-- applies text nor clears the new inflight state, and only the new result cleans.
test.it("replaces active same-group work and ignores its late callback", function()
  local active, editor, translator = start("A", 1)
  change(editor, "A1", 2)
  assert(active:sync_all())
  local old_task = translator.submitted[2]
  local old_handle = translator.pending[1].handle

  change(editor, "A2", 3)
  assert(active:sync_all())
  local new_task = translator.submitted[3]
  test.eq(true, old_handle.cancelled)
  test.eq("A2", new_task.edited_after.units[1].content_text)

  translator:complete_task(old_task.task_id)
  test.eq("初A", editor.documents.target.text)
  test.eq(new_task.task_id, active.mapping_graph.groups["group:000001"].inflight_task_id)

  translator:complete_task(new_task.task_id)
  test.eq("訳A2", editor.documents.target.text)
  test.eq("clean", active.mapping_graph.groups["group:000001"].state)
end)

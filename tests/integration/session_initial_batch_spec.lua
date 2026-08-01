local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local deferred_translation = require("tests.fakes.deferred_translation_service")

local function config()
  return {
    source_language = "en",
    target_language = "ja",
    limits = {
      max_document_bytes = 4096,
      max_units = 50,
      max_task_output_chars = 4096,
      initial_batch_chars = 99,
      initial_batch_units = 2,
    },
    sync = { max_concurrency = 2, context_groups = 1, structural_changes = "auto_safe" },
    ui = { show_progress = true },
  }
end

-- Preconditions: Five paragraphs require three initial batches under a two-unit
-- ceiling, and two requests may run concurrently. Prerequisites: The deferred
-- Fake TranslationService can complete tasks out of submission order.
-- Verification items: the target stays unmodifiable until all batches succeed,
-- at most two requests are initially active, and final assembly follows source
-- unit order rather than callback order while retaining every exact ID; progress
-- reports 0 through 3 completed batches and is cleared when startup finishes.
test.it("assembles bounded initial batches by unit ID after out-of-order completion", function()
  local editor = fake_editor.new("A\n\nBB\n\nCCC\n\nD\n\nEE", "text")
  local progress = {}
  function editor:render_initial_progress(update)
    progress[#progress + 1] = update and ("%d/%d"):format(update.completed, update.total) or "clear"
  end
  local translator = deferred_translation.new(function(task)
    local replacements = {}
    for index, unit in ipairs(task.edited_after.units) do
      replacements[index] = {
        local_id = task.task_id .. ":" .. index,
        corresponds_to_edited_unit_ids = { unit.unit_id },
        kind = unit.kind,
        content_text = "J" .. unit.content_text,
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
  end, function()
    return true
  end)
  local active = session_module.new({
    id = "session:batches",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = config(),
  })
  local started
  active:start(function(ok)
    started = ok
  end)

  test.eq(2, #translator.submitted)
  test.eq(false, editor.target_modifiable)
  translator:complete_task(translator.submitted[2].task_id)
  test.eq(3, #translator.submitted)
  translator:complete_task(translator.submitted[1].task_id)
  test.eq(nil, started)
  translator:complete_task(translator.submitted[3].task_id)

  test.eq(true, started)
  test.eq("JA\n\nJBB\n\nJCCC\n\nJD\n\nJEE", editor.documents.target.text)
  test.eq(true, editor.target_modifiable)
  test.eq(5, #active.mapping_graph.order)
  test.eq({ "0/3", "1/3", "2/3", "3/3", "clear" }, progress)
end)

-- Preconditions: A single translatable paragraph contains more Unicode
-- characters than limits.initial_batch_chars. Prerequisites: Units are atomic
-- translation inputs and therefore cannot be split merely to satisfy a batch
-- limit. Verification items: startup fails with E_DOCUMENT_TOO_LARGE before any
-- task is submitted, no partial target becomes editable, and owned resources are
-- cleaned up.
test.it("rejects a single unit larger than the initial character limit", function()
  local editor = fake_editor.new("Oversized", "text")
  local translator = deferred_translation.new(function()
    error("an oversized unit must not be submitted")
  end)
  local limits = config()
  limits.limits.initial_batch_chars = 4
  local active = session_module.new({
    id = "session:oversized-unit",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = limits,
  })
  local started, start_error

  active:start(function(ok, err)
    started, start_error = ok, err
  end)

  test.eq(nil, started)
  test.eq("E_DOCUMENT_TOO_LARGE", start_error.code)
  test.eq(0, #translator.submitted)
  test.eq(false, editor.target_modifiable)
  test.eq(true, editor.disposed)
end)

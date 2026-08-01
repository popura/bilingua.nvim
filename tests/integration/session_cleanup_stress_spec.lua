local generated_id = require("bilingua.adapters.aligner.generated_id")
local plaintext = require("bilingua.adapters.document.plaintext")
local session_module = require("bilingua.app.session")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")
local test = require("tests.testlib")

local function result_for(task)
  local replacements = {}
  for index, unit in ipairs(task.edited_after.units) do
    replacements[index] = {
      local_id = ("initial:%d"):format(index),
      corresponds_to_edited_unit_ids = { unit.unit_id },
      kind = unit.kind,
      content_text = ("訳文 %d"):format(index),
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

-- Preconditions: Each iteration creates a fresh Session with its own editor,
-- change subscriptions, mapping graph, synchronization engine, and translation
-- service. Prerequisites: start and force stop are synchronous with these fakes,
-- and force stop must be idempotent. Verification items: after 25 complete
-- lifecycles every service was closed exactly once, each editor and subscription
-- was disposed, and no Session retains document, graph, engine, or active-job state.
test.it("does not accumulate owned resources across repeated start and stop", function()
  for iteration = 1, 25 do
    local editor = fake_editor.new(("Source %d"):format(iteration), "text")
    local translator = fake_translation.new(result_for)
    local close_calls = 0
    local close = translator.close
    translator.close = function(self, callback)
      close_calls = close_calls + 1
      return close(self, callback)
    end
    local session = session_module.new({
      id = ("session:cleanup:%d"):format(iteration),
      editor = editor,
      document_adapter = plaintext.new(),
      unit_tracker = hybrid.new(),
      aligner = generated_id.new(),
      translator = translator,
      config = {
        source_language = "en",
        target_language = "ja",
        limits = {
          max_document_bytes = 1024,
          max_units = 20,
          max_task_output_chars = 1024,
        },
        sync = { context_groups = 1 },
      },
    })

    local started
    session:start(function(ok, err)
      assert(ok, err and err.message)
      started = ok
    end)
    test.eq(true, started)

    local stopped, stop_error = session:stop({ force = true })

    test.eq(true, stopped)
    test.eq(nil, stop_error)
    test.eq(1, close_calls)
    test.eq("closed", translator.state)
    test.eq("stopped", session.state)
    test.eq("disposed", session.health)
    test.eq(true, editor.disposed)
    test.eq(nil, editor.documents.target)
    test.eq(nil, editor.subscriptions.source)
    test.eq(nil, editor.subscriptions.target)
    test.eq({}, session.subscriptions)
    test.eq({}, session.active_jobs)
    test.eq(nil, session.mapping_graph)
    test.eq(nil, session.source_snapshot)
    test.eq(nil, session.target_snapshot)
    test.eq(nil, session.sync_engine)
    test.eq(nil, session.translator)
  end
end)

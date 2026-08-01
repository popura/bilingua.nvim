local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local deferred_translation = require("tests.fakes.deferred_translation_service")

local function scheduler()
  local timers = {}
  return {
    timers = timers,
    defer = function(_, milliseconds, callback)
      local timer = { milliseconds = milliseconds, callback = callback, cancelled = false }
      function timer:cancel()
        self.cancelled = true
      end
      function timer:fire()
        if self.cancelled then
          return
        end
        self.cancelled = true
        self.callback()
      end
      timers[#timers + 1] = timer
      return timer
    end,
  }
end

-- Preconditions: The only initial batch is in flight when the source changes.
-- Prerequisites: source changedtick is authoritative even if backend cancellation
-- races with completion; restart waits sync.debounce_ms and reparses the full
-- latest document. Verification items: stale output never reaches the target,
-- start remains pending, one restart timer is scheduled, and its next task/result
-- completes the same Session with the newest source text.
test.it("restarts initial translation after a debounced source edit", function()
  local editor = fake_editor.new("Old", "text")
  local clock = scheduler()
  local translator = deferred_translation.new(function(task)
    local unit = task.edited_after.units[1]
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = task.task_id .. ":1",
          corresponds_to_edited_unit_ids = { unit.unit_id },
          kind = "paragraph",
          content_text = unit.content_text == "New" and "新" or "旧",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end, function()
    return true
  end)
  local active = session_module.new({
    id = "session:initial-stale",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    scheduler = clock,
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
        debounce_ms = 25,
        max_concurrency = 1,
        context_groups = 1,
        structural_changes = "auto_safe",
      },
    },
  })
  local started, start_error
  active:start(function(ok, err)
    started, start_error = ok, err
  end)

  editor.documents.source.text = "New"
  editor.documents.source.version = 2
  translator:complete_next()

  test.eq(nil, started)
  test.eq(nil, start_error)
  test.eq("", editor.documents.target.text)
  test.eq(1, #clock.timers)
  test.eq(25, clock.timers[1].milliseconds)

  clock.timers[1]:fire()
  test.eq(2, #translator.submitted)
  test.eq("New", translator.submitted[2].edited_after.units[1].content_text)
  translator:complete_next()

  test.eq(true, started)
  test.eq(nil, start_error)
  test.eq("新", editor.documents.target.text)
  test.eq("ready", active.state)
end)

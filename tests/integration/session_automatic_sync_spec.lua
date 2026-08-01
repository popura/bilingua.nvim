local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

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

local function start_session(clock)
  local editor = fake_editor.new("A", "text")
  local translator = fake_translation.new(function(task)
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
          content_text = task.kind == "initial_translate" and "甲" or "訳" .. unit.content_text,
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local active = session_module.new({
    id = "session:automatic",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    scheduler = clock,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 4096, max_units = 20, max_task_output_chars = 4096 },
      sync = {
        automatic = true,
        debounce_ms = 40,
        on_insert_leave = true,
        max_concurrency = 1,
        context_groups = 1,
        structural_changes = "auto_safe",
      },
    },
  })
  active:start(function(ok, err)
    assert(ok, err and err.message)
  end)
  return active, editor, translator
end

local function edit(editor, text, version, extra)
  editor.documents.source.text = text
  editor.documents.source.version = version
  local change = {
    side = "source",
    version = version,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 0, col = #text } } },
    origin = "user",
    full_reload = false,
  }
  for key, value in pairs(extra or {}) do
    change[key] = value
  end
  editor.subscriptions.source(change)
end

-- Preconditions: Two normal source edits occur before the 40 ms debounce expires.
-- Prerequisites: change callbacks only aggregate ranges and restart a Session-side
-- timer; parsing and translation occur when its scheduled callback fires.
-- Verification items: the first timer is cancelled, no per-keystroke task starts,
-- and one final task translates the newest complete text after the second timer.
test.it("debounces consecutive automatic synchronization changes", function()
  local clock = scheduler()
  local _, editor, translator = start_session(clock)

  edit(editor, "A1", 2)
  test.eq(1, #translator.submitted)
  test.eq(40, clock.timers[1].milliseconds)
  edit(editor, "A2", 3)
  test.eq(true, clock.timers[1].cancelled)
  test.eq(2, #clock.timers)
  test.eq(1, #translator.submitted)

  clock.timers[2]:fire()
  test.eq(2, #translator.submitted)
  test.eq("A2", translator.submitted[2].edited_after.units[1].content_text)
  test.eq("訳A2", editor.documents.target.text)
end)

-- Preconditions: A source change has a pending debounce timer when InsertLeave is
-- reported. Prerequisites: flush events carry no additional text range and may be
-- delivered directly by EditorPort. Verification items: the timer is cancelled,
-- synchronization runs immediately exactly once, and force stop leaves no live
-- Session timer that can submit another task later.
test.it("flushes automatic synchronization on InsertLeave and cancels timers on stop", function()
  local clock = scheduler()
  local active, editor, translator = start_session(clock)

  edit(editor, "B", 2)
  active:on_editor_change({
    side = "source",
    version = 2,
    ranges = {},
    origin = "user",
    flush = true,
  })

  test.eq(true, clock.timers[1].cancelled)
  test.eq(2, #translator.submitted)
  test.eq("訳B", editor.documents.target.text)

  edit(editor, "C", 3)
  local pending_timer = clock.timers[#clock.timers]
  assert(active:stop({ force = true }))
  test.eq(true, pending_timer.cancelled)
  pending_timer:fire()
  test.eq(2, #translator.submitted)
end)

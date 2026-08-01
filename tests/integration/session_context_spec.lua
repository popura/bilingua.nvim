local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: The middle of three clean paragraph groups becomes source-dirty
-- with sync.context_groups=1. Prerequisites: context uses synchronized neighbor
-- baselines and represents each bilingual MappingGroup as separate source and
-- target fragments. Verification items: before/after each contain the correct
-- two side-tagged fragments, the edited middle group is absent from context, and
-- only its ID appears in replacement correspondence.
test.it("adds bounded bilingual neighbor context without expanding replacement scope", function()
  local editor = fake_editor.new("A\n\nB\n\nC", "text")
  local observed_patch
  local translator = fake_translation.new(function(task)
    if task.kind == "initial_translate" then
      local replacements = {}
      for index, unit in ipairs(task.edited_after.units) do
        replacements[index] = {
          local_id = "initial:" .. index,
          corresponds_to_edited_unit_ids = { unit.unit_id },
          kind = "paragraph",
          content_text = ({ "甲", "乙", "丙" })[index],
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
    observed_patch = task
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = "patch:middle",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = "乙二",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local active = session_module.new({
    id = "session:context",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 4096, max_units = 20, max_task_output_chars = 4096 },
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

  editor.documents.source.text = "A\n\nB2\n\nC"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 2, col = 0 }, finish = { row = 2, col = 2 } } },
    origin = "user",
    full_reload = false,
  })
  assert(active:sync_all())

  test.eq(2, #observed_patch.context_before)
  test.eq("source", observed_patch.context_before[1].side)
  test.eq("A", observed_patch.context_before[1].units[1].content_text)
  test.eq("target", observed_patch.context_before[2].side)
  test.eq("甲", observed_patch.context_before[2].units[1].content_text)
  test.eq(2, #observed_patch.context_after)
  test.eq("C", observed_patch.context_after[1].units[1].content_text)
  test.eq("丙", observed_patch.context_after[2].units[1].content_text)
  test.eq(1, #observed_patch.edited_after.units)
  test.eq("B2", observed_patch.edited_after.units[1].content_text)
end)

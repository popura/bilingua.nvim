local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_editor = require("tests.fakes.editor")
local fake_translation = require("tests.fakes.translation_service")

local function config(structural_changes)
  return {
    source_language = "en",
    target_language = "ja",
    limits = { max_document_bytes = 4096, max_units = 50, max_task_output_chars = 4096 },
    sync = { context_groups = 1, structural_changes = structural_changes or "auto_safe" },
  }
end

local function session(editor, translator, id, structural_changes)
  return session_module.new({
    id = id,
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = translator,
    config = config(structural_changes),
  })
end

-- Preconditions: A ready A/B source and あ/い target gain a new leading source
-- paragraph X. Prerequisites: Tracker reports insert, aligner creates a source-only
-- group before existing groups, and the adapter receives neighboring target IDs as
-- an insertion anchor. Verification items: one propagate_structure task inserts
-- the Japanese block at the corresponding leading position, attaches the new
-- target ID to the same group, and leaves every group clean.
test.it("propagates a leading paragraph insertion to the empty target side", function()
  local editor = fake_editor.new("A\n\nB", "text")
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
            content_text = "あ",
            language = "ja",
          },
          {
            local_id = "initial:2",
            corresponds_to_edited_unit_ids = { task.edited_after.units[2].unit_id },
            kind = "paragraph",
            content_text = "い",
            language = "ja",
          },
        },
        warnings = {},
        metadata = {},
      }
    end
    test.eq("propagate_structure", task.kind)
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = "insert:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = "えっくす",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local active = session(editor, translator, "session:insert")
  active:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "X\n\nA\n\nB"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 1, col = 0 } } },
    origin = "user",
  })
  local synced, sync_error = active:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq("えっくす\n\nあ\n\nい", editor.documents.target.text)
  local leading = active.mapping_graph.groups[active.mapping_graph.order[1]]
  test.eq(1, #leading.source_unit_ids)
  test.eq(1, #leading.target_unit_ids)
  test.eq("clean", leading.state)
end)

-- Preconditions: One synchronized paragraph is split into two source paragraphs
-- by a blank line. Prerequisites: Tracker applies its split ID rule, the original
-- mapping group becomes one-to-many, and Plaintext plan_replace renders two whole
-- replacement units separated by one blank line. Verification items: the task is
-- structural, target parsing inherits/allocates both IDs into the same group, and
-- the new two-by-two baseline is clean.
test.it("propagates a paragraph split within one mapping group", function()
  local editor = fake_editor.new("Alpha Beta", "text")
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
            content_text = "アルファベータ",
            language = "ja",
          },
        },
        warnings = {},
        metadata = {},
      }
    end
    test.eq("propagate_structure", task.kind)
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = "split:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = "アルファ",
          language = "ja",
        },
        {
          local_id = "split:2",
          corresponds_to_edited_unit_ids = { task.edited_after.units[2].unit_id },
          kind = "paragraph",
          content_text = "ベータ",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local active = session(editor, translator, "session:split")
  active:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "Alpha\n\nBeta"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 2, col = 4 } } },
    origin = "user",
  })
  local synced, sync_error = active:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq("アルファ\n\nベータ", editor.documents.target.text)
  local group = active.mapping_graph.groups[active.mapping_graph.order[1]]
  test.eq(2, #group.source_unit_ids)
  test.eq(2, #group.target_unit_ids)
  test.eq("clean", group.state)
end)

-- Preconditions: Two clean one-to-one paragraph groups are joined into one source
-- paragraph. Prerequisites: Tracker merge reconciliation consolidates both groups
-- before task creation so the semantic patch sees the complete old bilingual pair.
-- Verification items: exactly one structural task carries two old source units,
-- one current source unit and two target units; one replacement is applied; and
-- the resulting one-to-one group establishes a clean baseline.
test.it("propagates a paragraph merge across mapping groups", function()
  local editor = fake_editor.new("A\n\nB", "text")
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
            content_text = "あ",
            language = "ja",
          },
          {
            local_id = "initial:2",
            corresponds_to_edited_unit_ids = { task.edited_after.units[2].unit_id },
            kind = "paragraph",
            content_text = "い",
            language = "ja",
          },
        },
        warnings = {},
        metadata = {},
      }
    end
    test.eq("propagate_structure", task.kind)
    test.eq(2, #task.edited_before.units)
    test.eq(1, #task.edited_after.units)
    test.eq(2, #task.destination_before.units)
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = "merge:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = "あい",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local active = session(editor, translator, "session:merge")
  active:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "A B"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 0, col = 1 }, finish = { row = 2, col = 0 } } },
    origin = "user",
  })
  local synced, sync_error = active:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq(2, #translator.submitted)
  test.eq("あい", editor.documents.target.text)
  test.eq(1, #active.mapping_graph.order)
  local group = active.mapping_graph.groups[active.mapping_graph.order[1]]
  test.eq(1, #group.source_unit_ids)
  test.eq(1, #group.target_unit_ids)
  test.eq("clean", group.state)
end)

-- Preconditions: The second source paragraph and its one-to-one target group are
-- clean before the source paragraph is deleted. Prerequisites: Tracker and Aligner
-- leave a source-empty provisional group, and Semantic Patch represents deletion
-- with an empty replacement list. Verification items: one structural task carries
-- the old source and target units, removes the target paragraph plus its separator,
-- removes the now-empty group, and leaves the surviving group clean.
test.it("propagates a paragraph deletion and removes the empty group", function()
  local editor = fake_editor.new("A\n\nB", "text")
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
            content_text = "あ",
            language = "ja",
          },
          {
            local_id = "initial:2",
            corresponds_to_edited_unit_ids = { task.edited_after.units[2].unit_id },
            kind = "paragraph",
            content_text = "い",
            language = "ja",
          },
        },
        warnings = {},
        metadata = {},
      }
    end
    test.eq("propagate_structure", task.kind)
    test.eq(1, #task.edited_before.units)
    test.eq(0, #task.edited_after.units)
    test.eq(1, #task.destination_before.units)
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {},
      warnings = {},
      metadata = {},
    }
  end)
  local active = session(editor, translator, "session:delete")
  active:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "A"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 0, col = 1 }, finish = { row = 2, col = 1 } } },
    origin = "user",
  })
  local synced, sync_error = active:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq(2, #translator.submitted)
  test.eq("あ", editor.documents.target.text)
  test.eq(1, #active.mapping_graph.order)
  test.eq("clean", active.mapping_graph.groups[active.mapping_graph.order[1]].state)
end)

-- Preconditions: A ready two-paragraph Session disables structural
-- synchronization and the source gains one leading paragraph. Prerequisites:
-- the tracker can identify the insertion, but policy rejects propagation before
-- any backend task is submitted. Verification items: sync_all returns
-- E_STRUCTURE_UNSUPPORTED, the affected mapping group is invalid, and the target
-- text and backend submission count remain unchanged across a repeated retry;
-- undoing the insertion reparses the group back to clean.
test.it("marks a disabled structural edit invalid without submitting it", function()
  local editor = fake_editor.new("A\n\nB", "text")
  local translator = fake_translation.new(function(task)
    test.eq("initial_translate", task.kind)
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = "initial:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = "あ",
          language = "ja",
        },
        {
          local_id = "initial:2",
          corresponds_to_edited_unit_ids = { task.edited_after.units[2].unit_id },
          kind = "paragraph",
          content_text = "い",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local active = session(editor, translator, "session:structure-disabled", "disabled")
  active:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "X\n\nA\n\nB"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 1, col = 0 } } },
    origin = "user",
  })
  local synced, sync_error = active:sync_all()

  test.eq(nil, synced)
  test.eq("E_STRUCTURE_UNSUPPORTED", sync_error.code)
  local retried, retry_error = active:sync_all()
  test.eq(nil, retried)
  test.eq("E_STRUCTURE_UNSUPPORTED", retry_error.code)
  test.eq("あ\n\nい", editor.documents.target.text)
  test.eq(1, #translator.submitted)
  local invalid = 0
  for _, group_id in ipairs(active.mapping_graph.order) do
    if active.mapping_graph.groups[group_id].state == "invalid" then
      invalid = invalid + 1
    end
  end
  test.eq(1, invalid)

  editor.documents.source.text = "A\n\nB"
  editor.documents.source.version = 3
  editor.subscriptions.source({
    side = "source",
    version = 3,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 1, col = 0 } } },
    origin = "user",
  })
  local recovered, recovery_error = active:sync_all()

  test.eq(true, recovered)
  test.eq(nil, recovery_error)
  test.eq(1, #translator.submitted)
  local non_clean = 0
  for _, group_id in ipairs(active.mapping_graph.order) do
    if active.mapping_graph.groups[group_id].state ~= "clean" then
      non_clean = non_clean + 1
    end
  end
  test.eq(0, non_clean)
end)

-- Preconditions: One source edit changes paragraph A and inserts paragraph X
-- while structural synchronization uses manual policy. Prerequisites: the
-- tracker reports A as edited and X as inserted in the same reconciliation.
-- Verification items: only X's provisional group becomes conflict, A is sent as
-- propagate_edit and cleaned, B stays clean, and no translation is inserted for X.
test.it("isolates a manual structural conflict from an ordinary text edit", function()
  local editor = fake_editor.new("A\n\nB", "text")
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
            content_text = "あ",
            language = "ja",
          },
          {
            local_id = "initial:2",
            corresponds_to_edited_unit_ids = { task.edited_after.units[2].unit_id },
            kind = "paragraph",
            content_text = "い",
            language = "ja",
          },
        },
        warnings = {},
        metadata = {},
      }
    end
    test.eq("propagate_edit", task.kind)
    test.eq("A2", task.edited_after.units[1].content_text)
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = {
        {
          local_id = "edit:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = "あ二",
          language = "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
  local active = session(editor, translator, "session:structure-manual", "manual")
  active:start(function(ok, err)
    assert(ok, err and err.message)
  end)

  editor.documents.source.text = "A2\n\nX\n\nB"
  editor.documents.source.version = 2
  editor.subscriptions.source({
    side = "source",
    version = 2,
    ranges = { { start = { row = 0, col = 0 }, finish = { row = 3, col = 0 } } },
    origin = "user",
  })
  local synced, sync_error = active:sync_all()

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq(2, #translator.submitted)
  test.eq("あ二\n\nい", editor.documents.target.text)
  test.eq("clean", active.mapping_graph.groups[active.mapping_graph.order[1]].state)
  local structural_group = active.mapping_graph.groups[active.mapping_graph.order[2]]
  test.eq(1, #structural_group.source_unit_ids)
  test.eq(0, #structural_group.target_unit_ids)
  test.eq("conflict", structural_group.state)
  test.eq("clean", active.mapping_graph.groups[active.mapping_graph.order[3]].state)
end)

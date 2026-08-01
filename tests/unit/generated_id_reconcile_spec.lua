local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")

local function parse(side, text, previous)
  return assert(plaintext.new():parse({
    side = side,
    text = text,
    filetype = "text",
    language = side == "source" and "en" or "ja",
    editor_version = previous and 2 or 1,
    previous = previous,
  }))
end

local function initialized()
  local source = parse("source", "A\n\nB")
  local target = parse("target", "あ\n\nい")
  local graph = assert(generated_id.new():initialize({
    source_snapshot = source,
    target_snapshot = target,
    construction_seeds = {
      { source_unit_ids = { source.order[1] }, target_ordinal = 1, kind = "paragraph" },
      { source_unit_ids = { source.order[2] }, target_ordinal = 2, kind = "paragraph" },
    },
    initial_translation_result = {
      replacement_units = {
        { corresponds_to_edited_unit_ids = { source.order[1] } },
        { corresponds_to_edited_unit_ids = { source.order[2] } },
      },
    },
  }))
  return source, target, graph
end

-- Preconditions: An initialized two-group graph receives a new source paragraph
-- before both existing blocks. Prerequisites: Tracker assigns the insert a fresh
-- stable ID and reports its current ordinal. Verification items: reconciliation
-- creates an independent source-only provisional group in document order, retains
-- both original groups, and uses a valid empty source/target baseline pair.
test.it("creates an ordered provisional group for a structural insertion", function()
  local source, _, graph = initialized()
  local current = parse("source", "X\n\nA\n\nB", source)
  local report = assert(hybrid.new():reconcile({
    side = "source",
    previous = source,
    current = current,
    changed_ranges = {},
    anchor_hints = {},
  }))
  local reconciled, align_error = generated_id.new():reconcile({
    graph = graph,
    changed_side = "source",
    previous_snapshot = source,
    current_snapshot = report.snapshot,
    tracking_report = report,
  })

  test.eq(nil, align_error)
  local inserted = reconciled.groups[reconciled.order[1]]
  test.eq({ "src:u:000003" }, inserted.source_unit_ids)
  test.eq({}, inserted.target_unit_ids)
  test.eq(true, inserted.metadata.provisional)
  test.eq("source", inserted.baseline.source.side)
  test.eq(0, #inserted.baseline.source.units)
  test.eq("group:000001", reconciled.order[2])
end)

-- Preconditions: The first source paragraph of an initialized group is split into
-- two units while the target remains one unit. Prerequisites: Tracker reports one
-- split with stable IDs and the aligner permits one-to-many membership.
-- Verification items: both split source IDs stay in the original group, no extra
-- provisional group is created, and the target membership remains unchanged.
test.it("keeps split units in their existing mapping group", function()
  local source, target, graph = initialized()
  local current = parse("source", "A one\n\nA two\n\nB", source)
  -- Make the first old paragraph semantically equivalent to the split pair so the
  -- tracker can establish a deterministic split relation for this fixture.
  source.units[source.order[1]].content_text = "A one A two"
  source.units[source.order[1]].fingerprint = require("bilingua.util.hash").sha256("A one A two")
  local report = assert(hybrid.new():reconcile({
    side = "source",
    previous = source,
    current = current,
    changed_ranges = {},
    anchor_hints = {},
  }))
  local reconciled = assert(generated_id.new():reconcile({
    graph = graph,
    changed_side = "source",
    previous_snapshot = source,
    current_snapshot = report.snapshot,
    tracking_report = report,
  }))

  test.eq({ "src:u:000001", "src:u:000003" }, reconciled.groups["group:000001"].source_unit_ids)
  test.eq({ target.order[1] }, reconciled.groups["group:000001"].target_unit_ids)
  test.eq(2, #reconciled.order)
end)

-- Preconditions: Two adjacent source units in distinct one-to-one groups become
-- one source unit, and Tracker reports one merge relation spanning both old IDs.
-- Prerequisites: A unit cannot belong to two mapping groups, so Generated-ID
-- reconciliation must consolidate the affected groups and their baseline pairs.
-- Verification items: one group owns the merged source ID and both target IDs,
-- both sides of the baseline retain both old units, and no target orphan remains.
test.it("consolidates mapping groups for a merge across group boundaries", function()
  local source, target, graph = initialized()
  local current = parse("source", "A B", source)
  local report = assert(hybrid.new():reconcile({
    side = "source",
    previous = source,
    current = current,
    changed_ranges = {},
    anchor_hints = {},
  }))
  local reconciled = assert(generated_id.new():reconcile({
    graph = graph,
    changed_side = "source",
    previous_snapshot = source,
    current_snapshot = report.snapshot,
    tracking_report = report,
  }))

  test.eq(1, #reconciled.order)
  local group = reconciled.groups[reconciled.order[1]]
  test.eq({ source.order[1] }, group.source_unit_ids)
  test.eq({ target.order[1], target.order[2] }, group.target_unit_ids)
  test.eq(2, #group.baseline.source.units)
  test.eq(2, #group.baseline.target.units)
  test.eq(true, group.metadata.structural_change)
end)

-- Preconditions: The second source unit is deleted from an initialized pair of
-- one-to-one groups. Prerequisites: Delete reconciliation retains the opposite
-- side as an explicit orphan so a later structural sync can remove or regenerate
-- it. Verification items: the surviving group is unchanged and the deleted
-- source group becomes a target-only provisional structural group.
test.it("retains a deleted unit as an explicit provisional orphan", function()
  local source, target, graph = initialized()
  local current = parse("source", "A", source)
  local report = assert(hybrid.new():reconcile({
    side = "source",
    previous = source,
    current = current,
    changed_ranges = {},
    anchor_hints = {},
  }))
  local reconciled = assert(generated_id.new():reconcile({
    graph = graph,
    changed_side = "source",
    previous_snapshot = source,
    current_snapshot = report.snapshot,
    tracking_report = report,
  }))

  test.eq(2, #reconciled.order)
  test.eq({ source.order[1] }, reconciled.groups["group:000001"].source_unit_ids)
  local orphan = reconciled.groups["group:000002"]
  test.eq({}, orphan.source_unit_ids)
  test.eq({ target.order[2] }, orphan.target_unit_ids)
  test.eq(true, orphan.metadata.provisional)
  test.eq(true, orphan.metadata.structural_change)
end)

local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")

local function snapshot(text, previous)
  return assert(plaintext.new():parse({
    side = "source",
    text = text,
    filetype = "text",
    language = "en",
    editor_version = previous and 2 or 1,
    previous = previous,
  }))
end

local function reconcile(previous, current, anchor_hints)
  return hybrid.new():reconcile({
    side = "source",
    previous = previous,
    current = current,
    changed_ranges = {},
    anchor_hints = anchor_hints or {},
  })
end

local function find_match(report, kind)
  for _, match in ipairs(report.matches) do
    if match.kind == kind then
      return match
    end
  end
end

-- Preconditions: One old paragraph is split at a newly inserted blank line into
-- two consecutive paragraphs whose normalized concatenation is unchanged.
-- Prerequisites: Split identity belongs to the original first part while later
-- parts receive fresh IDs. Verification items: one split relation records all
-- correspondence edges, inherits the old ID once, and allocates one collision-free
-- new ID without also reporting insert/delete for those units.
test.it("reports a paragraph split and applies the split ID rule", function()
  local previous = snapshot("Alpha Beta")
  local current = snapshot("Alpha\n\nBeta", previous)
  local report, tracking_error = reconcile(previous, current)

  test.eq(nil, tracking_error)
  local split = assert(find_match(report, "split"))
  test.eq({ previous.order[1] }, split.old_ids)
  test.eq({ "src:u:000001", "src:u:000002" }, split.new_ids)
  test.eq({ "src:u:000001", "src:u:000002" }, report.old_to_new[previous.order[1]])
  test.eq({ previous.order[1] }, report.new_to_old["src:u:000002"])
end)

-- Preconditions: Two consecutive old paragraphs are joined by deleting their
-- blank separator, producing one paragraph with equivalent normalized content.
-- Prerequisites: Merge identity is inherited from the first old unit and the
-- second old ID remains visible in the tracking relation. Verification items:
-- both old IDs map to one stable new ID and exactly one merge is reported.
test.it("reports a paragraph merge and applies the merge ID rule", function()
  local previous = snapshot("Alpha\n\nBeta")
  local current = snapshot("Alpha Beta", previous)
  local report, tracking_error = reconcile(previous, current)

  test.eq(nil, tracking_error)
  local merge = assert(find_match(report, "merge"))
  test.eq({ previous.order[1], previous.order[2] }, merge.old_ids)
  test.eq({ previous.order[1] }, merge.new_ids)
  test.eq({ previous.order[1] }, report.old_to_new[previous.order[2]])
  test.eq({ previous.order[1], previous.order[2] }, report.new_to_old[previous.order[1]])
end)

-- Preconditions: Three unique paragraphs are reordered from A/B/C to C/A/B
-- without content edits. Prerequisites: A leading insertion would preserve the
-- relative order of old matches, whereas this permutation introduces inversions.
-- Verification items: stable IDs follow content, at least the displaced C unit is
-- classified as move, and the report does not silently reduce it to same.
test.it("detects a block move from changed matched-neighbor order", function()
  local previous = snapshot("A\n\nB\n\nC")
  local current = snapshot("C\n\nA\n\nB", previous)
  local report = assert(reconcile(previous, current))

  test.eq({ "src:u:000003", "src:u:000001", "src:u:000002" }, report.snapshot.order)
  local moved_c = false
  for _, match in ipairs(report.matches) do
    if match.kind == "move" and match.old_ids[1] == "src:u:000003" then
      moved_c = true
    end
  end
  test.eq(true, moved_c)
end)

-- Preconditions: Two old and two current paragraphs have identical fingerprints,
-- and no extmark anchors are available to distinguish occurrences.
-- Prerequisites: Fingerprint collisions cannot be resolved from content or ordinal
-- alone. Verification items: the report marks ambiguity, inherits neither old ID,
-- gives current units fresh IDs, and exposes no fabricated old-to-new edge.
test.it("does not invent correspondence for indistinguishable duplicates", function()
  local previous = snapshot("Same\n\nSame")
  local current = snapshot("Same\n\nSame", previous)
  local report = assert(reconcile(previous, current))

  test.eq(true, report.ambiguous)
  test.eq({ "src:u:000003", "src:u:000004" }, report.snapshot.order)
  test.eq({}, report.old_to_new["src:u:000001"])
  test.eq({}, report.old_to_new["src:u:000002"])
  test.eq(true, find_match(report, "ambiguous") ~= nil)
end)

-- Preconditions: The same duplicate paragraphs have valid extmark ranges that
-- each overlap exactly one current unit. Prerequisites: Anchors are positional
-- hints, not persistent IDs, but mutual strong overlap removes the tie.
-- Verification items: both old IDs are inherited, ambiguity is false, and both
-- relations are classified as unchanged.
test.it("uses mutual anchor overlap to disambiguate duplicate blocks", function()
  local previous = snapshot("Same\n\nSame")
  local current = snapshot("Same\n\nSame", previous)
  local report = assert(reconcile(previous, current, {
    [previous.order[1]] = { range = current.units[current.order[1]].span, invalid = false },
    [previous.order[2]] = { range = current.units[current.order[2]].span, invalid = false },
  }))

  test.eq(false, report.ambiguous)
  test.eq(previous.order, report.snapshot.order)
  for _, match in ipairs(report.matches) do
    test.eq("same", match.kind)
  end
end)

-- Preconditions: One unique paragraph changes a small amount while its unchanged
-- neighbor remains in place. Prerequisites: A content fingerprint is evidence but
-- not the persistent identity itself; unique structure and ordinal can retain an
-- edited unit. Verification items: both stable IDs survive, the changed relation
-- is edited, and the unchanged neighbor remains same.
test.it("preserves a stable ID across a mild block edit", function()
  local previous = snapshot("Alpha\n\nBeta")
  local current = snapshot("Alpha revised\n\nBeta", previous)
  local report = assert(reconcile(previous, current))

  test.eq(previous.order, report.snapshot.order)
  test.eq("Alpha revised", report.snapshot.units[previous.order[1]].content_text)
  test.eq("edited", assert(find_match(report, "edited")).kind)
  test.eq({ previous.order[1] }, report.old_to_new[previous.order[1]])
  test.eq({ previous.order[2] }, report.old_to_new[previous.order[2]])
end)

-- Preconditions: The second of two unique paragraphs is removed without changing
-- the first. Prerequisites: An unmatched old unit is a deletion and must not be
-- assigned to a surviving unit. Verification items: the first ID remains stable,
-- the deleted ID has an empty correspondence, and exactly one delete is reported.
test.it("reports deletion without fabricating correspondence", function()
  local previous = snapshot("Alpha\n\nBeta")
  local current = snapshot("Alpha", previous)
  local report = assert(reconcile(previous, current))
  local deletion = assert(find_match(report, "delete"))

  test.eq({ previous.order[1] }, report.snapshot.order)
  test.eq({ previous.order[1] }, report.old_to_new[previous.order[1]])
  test.eq({}, report.old_to_new[previous.order[2]])
  test.eq({ previous.order[2] }, deletion.old_ids)
  test.eq({}, deletion.new_ids)
end)

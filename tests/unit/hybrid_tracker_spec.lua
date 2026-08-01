local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")

-- Preconditions: A previous snapshot has paragraphs A and B, while the current
-- parse inserts X before both and therefore assigns provisional ordinal IDs.
-- Prerequisites: Stable identity is based on fingerprints and neighborhood, not
-- current line numbers or current ordinals. Verification items: A and B inherit
-- their old IDs, X receives a fresh non-colliding ID, and the report identifies
-- one insert plus two unchanged matches in the new document order.
test.it("preserves existing IDs across a leading block insertion", function()
  local adapter = plaintext.new()
  local previous = assert(adapter:parse({
    side = "source",
    text = "A\n\nB",
    filetype = "text",
    language = "en",
    editor_version = 1,
  }))
  local current = assert(adapter:parse({
    side = "source",
    text = "X\n\nA\n\nB",
    filetype = "text",
    language = "en",
    editor_version = 2,
    previous = previous,
  }))
  local report, err = hybrid.new():reconcile({
    side = "source",
    previous = previous,
    current = current,
    changed_ranges = {
      { start = { row = 0, col = 0 }, finish = { row = 1, col = 0 } },
    },
    anchor_hints = {},
  })

  test.eq(nil, err)
  test.eq({ "src:u:000003", "src:u:000001", "src:u:000002" }, report.snapshot.order)
  test.eq("X", report.snapshot.units["src:u:000003"].content_text)
  test.eq({ "src:u:000001" }, report.old_to_new["src:u:000001"])
  test.eq({ "src:u:000002" }, report.old_to_new["src:u:000002"])
  test.eq("insert", report.matches[1].kind)
  test.eq("same", report.matches[2].kind)
  test.eq("same", report.matches[3].kind)
end)

local test = require("tests.testlib")
local ranges = require("bilingua.util.ranges")

-- Preconditions: The document is valid UTF-8 and contains one three-byte Japanese
-- character followed by a newline. Prerequisites: Public positions are zero-based
-- byte offsets and line breaks count as one byte internally. Verification items:
-- conversion in both directions counts bytes rather than Unicode code points and
-- maps the first byte after the newline to row 1, column 0.
test.it("converts UTF-8 byte offsets without counting code points", function()
  local text = "Aあ\nB"

  test.eq(4, ranges.position_to_offset(text, { row = 0, col = 4 }))
  test.eq({ row = 1, col = 0 }, ranges.offset_to_position(text, 5))
end)

-- Preconditions: Position conversion receives an empty document and a document
-- ending immediately after a newline. Prerequisites: Both offsets and positions
-- are zero-based and the document end is a valid exclusive boundary.
-- Verification items: empty/start/end round-trip exactly, while rows, columns,
-- and offsets beyond the corresponding document boundary raise an error.
test.it("handles empty and boundary positions while rejecting out-of-range values", function()
  test.eq(0, ranges.position_to_offset("", { row = 0, col = 0 }))
  test.eq({ row = 0, col = 0 }, ranges.offset_to_position("", 0))

  local text = "A\n"
  test.eq(0, ranges.position_to_offset(text, { row = 0, col = 0 }))
  test.eq(2, ranges.position_to_offset(text, { row = 1, col = 0 }))
  test.eq({ row = 1, col = 0 }, ranges.offset_to_position(text, #text))

  local valid_row = pcall(ranges.position_to_offset, text, { row = 2, col = 0 })
  local valid_column = pcall(ranges.position_to_offset, text, { row = 0, col = 2 })
  local valid_offset = pcall(ranges.offset_to_position, text, #text + 1)
  test.eq(false, valid_row)
  test.eq(false, valid_column)
  test.eq(false, valid_offset)
end)

local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")

-- Preconditions: The source text contains a two-line paragraph, two blank
-- separator lines, and a second paragraph ending in a multibyte character.
-- Prerequisites: Plaintext units are non-empty ranges separated by one or more
-- blank lines; positions are zero-based byte offsets and IDs do not encode line
-- numbers. Verification items: two ordered paragraph units are emitted, their
-- raw text and byte ranges are exact, and the original separator is retained.
test.it("parses plaintext paragraphs and retains their separators", function()
  local adapter = plaintext.new()
  local snapshot, err = adapter:parse({
    side = "source",
    text = "First line\ncontinues.\n\n\nSecond あ",
    filetype = "text",
    language = "en",
    editor_version = 7,
  })

  test.eq(nil, err)
  test.eq({ "src:u:000001", "src:u:000002" }, snapshot.order)
  test.eq("First line\ncontinues.", snapshot.units["src:u:000001"].raw_text)
  test.eq(
    { start = { row = 0, col = 0 }, finish = { row = 1, col = 10 } },
    snapshot.units["src:u:000001"].span
  )
  test.eq("Second あ", snapshot.units["src:u:000002"].content_text)
  test.eq(
    { start = { row = 4, col = 0 }, finish = { row = 4, col = 10 } },
    snapshot.units["src:u:000002"].span
  )
  test.eq({ "\n\n\n" }, snapshot.adapter_state.separators)
  test.eq(7, snapshot.editor_version)
end)

-- Preconditions: A Plaintext fixture contains a decomposed e-plus-combining-acute
-- sequence followed by a four-byte emoji and one final LF. Prerequisites: Adapter
-- spans use UTF-8 byte columns and parse state retains input bytes without Unicode
-- normalization. Verification items: fixture bytes, content, suffix, and the
-- exclusive finish column all remain exact.
test.it("preserves combining characters and emoji as exact UTF-8 bytes", function()
  local handle = assert(io.open("tests/fixtures/regressions/unicode.txt", "rb"))
  local text = assert(handle:read("*a"))
  handle:close()
  local expected = "Cafe" .. string.char(0xcc, 0x81) .. " 😀\n"
  local snapshot = assert(plaintext.new():parse({
    side = "source",
    text = text,
    filetype = "text",
    language = "en",
    editor_version = 1,
  }))

  test.eq(expected, text)
  test.eq(expected, snapshot.adapter_state.text)
  test.eq(expected:sub(1, -2), snapshot.units[snapshot.order[1]].content_text)
  test.eq(11, snapshot.units[snapshot.order[1]].span.finish.col)
  test.eq("\n", snapshot.adapter_state.suffix)
end)
